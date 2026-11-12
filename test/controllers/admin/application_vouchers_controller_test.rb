# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationVouchersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      FeatureFlag.enable!(:vouchers_enabled)
      Policy.find_or_create_by!(key: 'voucher_value_hearing_disability') { |policy| policy.value = 500 }
      load_seeded_email_templates('voucher_notifications_voucher_assigned')
      applicant = create(
        :constituent,
        hearing_disability: true,
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false
      )
      @application = create(:application, :completed, :voucher_fulfillment, user: applicant)
      sign_in_for_integration_test(@admin, bypass_mfa_enrollment: true)
    end

    test 'issuing through the application records a voucher and its actor then refuses duplicate issuance' do
      assert_difference('Voucher.count', 1) do
        post assign_voucher_admin_application_path(@application)
      end
      assert_redirected_to admin_application_path(@application)
      assert_equal 'Voucher assigned successfully', flash[:notice]
      voucher = @application.vouchers.sole
      assert_predicate voucher, :voucher_active?
      assert_operator voucher.initial_value, :>, 0
      event = voucher.events.find_by!(action: 'voucher_assigned')
      assert_equal @admin.id, event.user_id
      assert_equal @application.id, event.metadata['application_id']
      assert_equal 'manual', event.metadata['assignment_method']

      assert_no_difference ['Voucher.count', 'Event.count'] do
        post assign_voucher_admin_application_path(@application)
      end
      assert_redirected_to admin_application_path(@application)
      assert_equal 'Application is not eligible for a voucher', flash[:alert]
      assert_equal [voucher.id], @application.vouchers.ids
    end

    test 'disabled vouchers refuse issuance without a durable assignment' do
      FeatureFlag.disable!(:vouchers_enabled)
      assert_no_difference ['Voucher.count', 'Event.count'] do
        post assign_voucher_admin_application_path(@application)
      end
      assert_redirected_to admin_application_path(@application)
      assert_equal 'Vouchers are not enabled', flash[:alert]
      assert_empty @application.vouchers
    end

    test 'an issuance follow-up warning is displayed with the successful assignment notice' do
      warning = 'Voucher was issued, but follow-up work failed. Check delivery before retrying.'
      result = BaseService::Result.new(success: true, message: warning, data: { warning: true })
      Vouchers::IssuanceService.any_instance.stubs(:call).returns(result)
      post assign_voucher_admin_application_path(@application)
      assert_redirected_to admin_application_path(@application)
      assert_equal 'Voucher assigned successfully', flash[:notice]
      assert_equal warning, flash[:alert]
    end
  end
end
