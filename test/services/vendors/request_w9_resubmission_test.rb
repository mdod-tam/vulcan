# frozen_string_literal: true

require 'test_helper'

module Vendors
  class RequestW9ResubmissionTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      @actor = create(:admin)
      @vendor = create(:vendor, :with_w9)
      @vendor.update!(w9_status: :rejected)
      Vendors::RequestW9Resubmission.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: {}))
      @w9_review = create(:w9_review,
                          :rejected,
                          vendor: @vendor,
                          admin: @actor,
                          rejection_reason: 'Tax ID mismatch')
      @mailer_delivery = mock('w9-rejected-mailer-delivery')
      @mailer_delivery.stubs(:deliver_now).returns(true)
      @mailer = mock('w9-rejected-mailer')
      @mailer.stubs(:w9_rejected).returns(@mailer_delivery)
      @mailer.stubs(:w9_upload_requested).returns(@mailer_delivery)
      VendorNotificationsMailer.stubs(:with).returns(@mailer)
      Vendors::RequestW9Resubmission.any_instance.unstub(:call)
    end

    test 'creates secure W9 request notification and delivers rejection email with secure upload url' do
      VendorNotificationsMailer.expects(:with).with do |params|
        params[:vendor] == @vendor &&
          params[:w9_review] == @w9_review &&
          params[:secure_upload_url].match?(/secure_w9_form/)
      end.returns(@mailer)
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = assert_difference('VendorSecureRequestForm.count', 1) do
        assert_difference("Notification.where(action: 'w9_resubmission_requested').count", 1) do
          RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
        end
      end

      assert_predicate result, :success?
      form = result.data.fetch(:vendor_secure_request_form)
      token = Rack::Utils.parse_nested_query(URI.parse(result.data.fetch(:secure_upload_url)).query).fetch('token')
      notification = Notification.find_by!(notifiable: @vendor, action: 'w9_resubmission_requested')

      assert_equal form.id, VendorSecureRequestForm.from_public_token(token).id
      assert_equal @vendor.email, form.recipient_email
      assert_equal form.id, notification.metadata.fetch('vendor_secure_request_form_id')
      assert_not notification.metadata.key?('secure_upload_url')
      assert_not notification.metadata.key?('raw_token')
    end

    test 'creates secure W9 request for not-submitted vendor and delivers upload request email' do
      vendor = create(:vendor)
      VendorNotificationsMailer.expects(:with).with do |params|
        params[:vendor] == vendor &&
          params[:w9_review].nil? &&
          params[:secure_upload_url].match?(/secure_w9_form/)
      end.returns(@mailer)
      @mailer.expects(:w9_upload_requested).returns(@mailer_delivery)
      @mailer_delivery.expects(:deliver_now).returns(true)

      result = assert_difference('VendorSecureRequestForm.count', 1) do
        assert_difference("Notification.where(action: 'w9_resubmission_requested').count", 1) do
          RequestW9Resubmission.new(vendor: vendor, actor: @actor).call
        end
      end

      assert_predicate result, :success?
      assert_equal vendor.email, result.data.fetch(:vendor_secure_request_form).recipient_email
    end

    test 'fails explicitly when vendor email is missing' do
      @vendor.stubs(:email).returns(nil)

      result = assert_no_difference('VendorSecureRequestForm.count') do
        RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.recipient_email_required', locale: @actor.effective_locale),
                   result.message
    end

    test 'fails when W9 state is not requestable' do
      vendor = create(:vendor, :with_w9)

      result = assert_no_difference('VendorSecureRequestForm.count') do
        RequestW9Resubmission.new(vendor: vendor, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.request_not_needed', locale: @actor.effective_locale),
                   result.message
    end

    test 'fails when rejected vendor has no rejected w9 review' do
      vendor = create(:vendor, :with_w9)
      vendor.update_column(:w9_status, Users::Vendor.w9_statuses[:rejected])

      result = assert_no_difference('VendorSecureRequestForm.count') do
        RequestW9Resubmission.new(vendor: vendor, actor: @actor).call
      end

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.missing_rejection_review', locale: @actor.effective_locale),
                   result.message
    end

    test 'staff resend during cooldown fails without creating replacement' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)

      result = assert_no_difference('VendorSecureRequestForm.count') do
        RequestW9Resubmission.new(
          vendor: @vendor,
          actor: @actor,
          resend_of: original
        ).call
      end

      assert_not result.success?
      assert_match(/minute/, result.message)
      assert_predicate original.reload, :status_sent?
    end

    test 'resend after cooldown revokes prior link and creates replacement' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)

      travel_to original.sent_at + 2.hours do
        result = RequestW9Resubmission.new(
          vendor: @vendor,
          actor: @actor,
          resend_of: original
        ).call

        assert_predicate result, :success?
      end

      assert_predicate original.reload, :revoked?
      assert_equal 1, VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: @vendor.id).count
    end

    test 'submitted secure link blocks a new secure W9 request during cooldown' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)
      original.mark_submitted!

      result = assert_no_difference('VendorSecureRequestForm.count') do
        RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      end

      assert_not result.success?
      assert_match(/minute/, result.message)
      assert_predicate original.reload, :submitted?
      assert_equal 0, VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: @vendor.id).count
    end

    test 'revoked secure link does not block a new secure W9 request during cooldown' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)
      original.revoke!(actor: @actor, reason: :manual_revocation)

      result = assert_difference('VendorSecureRequestForm.count', 1) do
        RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      end

      assert_predicate result, :success?
      assert_predicate original.reload, :revoked?
      assert_equal 1, VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: @vendor.id).count
    end

    test 'submitted secure link outside cooldown allows a new secure W9 request' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)
      original.mark_submitted!

      travel_to original.sent_at + 2.hours do
        result = assert_difference('VendorSecureRequestForm.count', 1) do
          RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
        end

        assert_predicate result, :success?
      end
    end

    test 'delivery failure revokes new secure request and records non-secret failure metadata' do
      @mailer_delivery.expects(:deliver_now).raises(StandardError, 'smtp timeout https://example.test/secure_w9_form?token=secret')

      result = assert_difference('VendorSecureRequestForm.count', 1) do
        assert_difference("Notification.where(action: 'w9_resubmission_requested').count", 1) do
          RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
        end
      end

      assert_not result.success?
      assert_equal I18n.t('vendors.w9_resubmission.messages.delivery_failed', locale: @actor.effective_locale),
                   result.message

      form = result.data.fetch(:vendor_secure_request_form)
      notification = Notification.find_by!(notifiable: @vendor, action: 'w9_resubmission_requested')
      delivery_error = notification.metadata.fetch('delivery_error')

      assert_predicate form.reload, :revoked?
      assert_equal 0, VendorSecureRequestForm.open_w9_upload_for_vendor(vendor_id: @vendor.id).count
      assert_equal 'error', notification.delivery_status
      assert_equal form.id, delivery_error.fetch('vendor_secure_request_form_id')
      assert_equal form.request_batch_id, delivery_error.fetch('request_batch_id')
      assert_equal 'StandardError', delivery_error.fetch('error_class')
      assert_includes delivery_error.fetch('error_message'), '[REDACTED_URL]'
      assert_not_includes notification.metadata.to_json, 'secret'
      assert_not notification.metadata.key?('secure_upload_url')
    end

    test 'public recovery is neutral during cooldown' do
      first_result = RequestW9Resubmission.new(vendor: @vendor, actor: @actor).call
      original = first_result.data.fetch(:vendor_secure_request_form)

      result = RequestW9Resubmission.new(
        vendor: @vendor,
        actor: @actor,
        resend_of: original,
        public_recovery: true
      ).call

      assert_predicate result, :success?
      assert_predicate original.reload, :status_sent?
    end
  end
end
