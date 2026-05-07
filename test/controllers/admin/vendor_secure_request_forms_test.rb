# frozen_string_literal: true

require 'test_helper'

module Admin
  class VendorSecureRequestFormsTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @vendor = create(:vendor, :with_w9)
      @vendor.update!(w9_status: :rejected)
      Vendors::RequestW9Resubmission.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: {}))
      create(:w9_review, :rejected, vendor: @vendor, admin: @admin)
    end

    test 'vendor show page offers secure W9 upload request button when vendor is rejected' do
      get admin_vendor_path(@vendor)

      assert_response :success
      assert_select "form[action='#{admin_vendor_vendor_secure_request_forms_path(@vendor)}']"
      assert_includes response.body, I18n.t('admin.vendors.vendor_secure_request_forms.panel.submit')
    end

    test 'vendor show page offers secure W9 upload request button when W9 is not submitted' do
      vendor = create(:vendor)

      get admin_vendor_path(vendor)

      assert_response :success
      assert_select "form[action='#{admin_vendor_vendor_secure_request_forms_path(vendor)}']"
      assert_includes response.body, I18n.t('admin.vendors.vendor_secure_request_forms.panel.submit')
    end

    test 'secure W9 upload request redirects with notice on success' do
      result = BaseService::Result.new(success: true, message: 'created', data: {})
      Vendors::RequestW9Resubmission.any_instance.expects(:call).returns(result)

      post admin_vendor_vendor_secure_request_forms_path(@vendor)

      assert_redirected_to admin_vendor_path(@vendor)
      assert_equal I18n.t('admin.vendors.vendor_secure_request_forms.create.success'), flash[:notice]
    end

    test 'secure W9 upload request redirects with failure message' do
      result = BaseService::Result.new(success: false, message: 'delivery failed', data: {})
      Vendors::RequestW9Resubmission.any_instance.expects(:call).returns(result)

      post admin_vendor_vendor_secure_request_forms_path(@vendor)

      assert_redirected_to admin_vendor_path(@vendor)
      assert_equal 'delivery failed', flash[:alert]
    end

    test 'show page renders secure W9 upload history table and revoke action' do
      form = create(:vendor_secure_request_form, vendor: @vendor)

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_includes response.body, "#{form.recipient_email.first}***@#{form.recipient_email.split('@', 2).last}"
      assert_select "form[action='#{admin_vendor_vendor_secure_request_form_revocation_path(@vendor, form)}']"
    end

    test 'show page offers a new secure W9 upload link after revocation' do
      form = create(:vendor_secure_request_form, :revoked, vendor: @vendor)

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_select "form[action='#{admin_vendor_vendor_secure_request_forms_path(@vendor, resend_of_id: form.id)}']"
      assert_includes response.body, I18n.t('admin.vendors.vendor_secure_request_forms.table.send_new_link')
    end

    test 'show page offers a new secure W9 upload link after revocation when W9 is not submitted' do
      vendor = create(:vendor)
      form = create(:vendor_secure_request_form, :revoked, vendor: vendor)

      get admin_vendor_path(vendor)

      assert_response :success
      assert_select "form[action='#{admin_vendor_vendor_secure_request_forms_path(vendor, resend_of_id: form.id)}']"
      assert_includes response.body, I18n.t('admin.vendors.vendor_secure_request_forms.table.send_new_link')
    end

    test 'individual revoke marks the targeted form revoked' do
      form = create(:vendor_secure_request_form, vendor: @vendor)

      post admin_vendor_vendor_secure_request_form_revocation_path(@vendor, form)

      assert_redirected_to admin_vendor_path(@vendor)
      assert_predicate form.reload, :revoked?
    end

    test 'vendor show page includes secure W9 upload revocation in W9 history' do
      form = create(:vendor_secure_request_form, vendor: @vendor)

      post admin_vendor_vendor_secure_request_form_revocation_path(@vendor, form)
      W9Review.where(vendor: @vendor).delete_all

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_includes response.body, 'Secure W9 upload link revoked'
      assert_includes response.body, "#{form.recipient_email.first}***@#{form.recipient_email.split('@', 2).last}"
      assert_not_includes response.body, 'No W9 reviews yet.'
    end

    test 'vendor show page includes secure W9 upload expiration in W9 history' do
      form = create(:vendor_secure_request_form, vendor: @vendor, requested_by: @admin, expires_at: 1.hour.ago)
      W9Review.where(vendor: @vendor).delete_all
      SecureFormExpirationRecorder.new.call

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_includes response.body, 'Secure W9 upload link expired'
      assert_includes response.body, "#{form.recipient_email.first}***@#{form.recipient_email.split('@', 2).last}"
      assert_not_includes response.body, 'No W9 reviews yet.'
    end

    test 'vendor show page includes secure W9 request issuance in W9 history' do
      W9Review.where(vendor: @vendor).delete_all
      Notification.create!(
        recipient: @vendor,
        actor: @admin,
        notifiable: @vendor,
        action: 'w9_resubmission_requested',
        metadata: {
          'vendor_id' => @vendor.id,
          'vendor_secure_request_form_id' => 801,
          'expires_at' => 2.days.from_now.iso8601
        }
      )

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_includes response.body, 'Secure W9 upload link sent'
      assert_includes response.body, 'Expires:'
      assert_not_includes response.body, 'No W9 reviews yet.'
    end

    test 'vendor show page includes secure W9 upload submission in W9 history' do
      form = create(:vendor_secure_request_form, :submitted, vendor: @vendor)
      W9Review.where(vendor: @vendor).delete_all
      Event.create!(
        user: @vendor,
        auditable: @vendor,
        action: 'w9_submitted_via_secure_form',
        metadata: {
          'vendor_id' => @vendor.id,
          'vendor_secure_request_form_id' => form.id,
          'request_batch_id' => form.request_batch_id
        }
      )

      get admin_vendor_path(@vendor)

      assert_response :success
      assert_includes response.body, 'Secure W9 uploaded for review'
      assert_not_includes response.body, 'No W9 reviews yet.'
    end

    test 'individual revoke redirects with alert when request is not active' do
      form = create(:vendor_secure_request_form, :submitted, vendor: @vendor)

      post admin_vendor_vendor_secure_request_form_revocation_path(@vendor, form)

      assert_redirected_to admin_vendor_path(@vendor)
      assert_equal I18n.t('admin.vendors.vendor_secure_request_form_revocations.create.not_active'), flash[:alert]
      assert_predicate form.reload, :submitted?
    end
  end
end
