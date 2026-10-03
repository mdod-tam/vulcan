# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  class VouchersControllerTest < ActionDispatch::IntegrationTest
    def setup
      @constituent = create(:constituent, date_of_birth: 25.years.ago.to_date)
      @vendor = create(:vendor, :approved)
      @application = create(:application, user: @constituent)
      @voucher = create(:voucher, :active, application: @application, vendor: @vendor)

      @headers = {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }

      sign_in_for_integration_test(@vendor)

      Policy.stubs(:voucher_minimum_redemption_amount).returns(10.0)
      Policy.stubs(:get).with('voucher_verification_max_attempts').returns(3)
      Policy.stubs(:get).with('voucher_validity_period_months').returns(6)
      Policy.stubs(:voucher_validity_period).returns(6.months)

      get vendor_portal_vouchers_path # initializes the session

      # Stubs replace the session-based identity verification.
      VendorPortal::VouchersController.any_instance.stubs(:identity_verified?).with(anything).returns(true)
      VendorPortal::VouchersController.any_instance.stubs(:check_identity_verified).returns(true)
      VendorPortal::VouchersController.any_instance.stubs(:check_voucher_active).returns(true)
    end

    def test_get_index
      get vendor_portal_vouchers_path
      assert_response :success
      assert_match(/vendor/i, response.body)
    end

    # Factory smoke test only. It does not call the controller.
    def test_voucher_operations
      assert_not_nil @voucher
      assert_not_nil @vendor
      assert_equal @voucher.vendor_id, @vendor.id
      assert_equal :active, @voucher.status.to_sym
    end

    # Model smoke test only. It does not call the controller.
    def test_with_correct_field_names
      assert @voucher.respond_to?(:initial_value)
      assert @voucher.respond_to?(:remaining_value)

      @voucher.update(initial_value: 500.0, remaining_value: 500.0)

      assert_equal 500.0, @voucher.initial_value.to_f
      assert_equal 500.0, @voucher.remaining_value.to_f
    end

    # The system tests cover the full redemption flow, including session and verification.
    def test_voucher_redemption_delegates_to_service
      @voucher.update(initial_value: 500.0, remaining_value: 500.0, issued_at: Time.current)

      @product = create(:product, name: 'Test Product', price: 50.0)

      mock_result = BaseService::Result.new(
        success: true,
        message: 'Voucher successfully processed',
        data: { transaction: build(:voucher_transaction), voucher: @voucher }
      )
      Vouchers::RedemptionService.stubs(:call).returns(mock_result)

      post process_redemption_vendor_portal_voucher_path(@voucher.code),
           params: { amount: 100.0, product_ids: [@product.id], notes: 'Test notes' }

      assert_redirected_to vendor_portal_dashboard_path
      assert_equal 'Voucher successfully processed', flash[:notice]
    end

    def test_voucher_redemption_handles_service_failure
      @voucher.update(initial_value: 500.0, remaining_value: 500.0, issued_at: Time.current)

      mock_result = BaseService::Result.new(
        success: false,
        message: 'Identity verification is required before redemption',
        data: nil
      )
      Vouchers::RedemptionService.stubs(:call).returns(mock_result)

      post process_redemption_vendor_portal_voucher_path(@voucher.code),
           params: { amount: 100.0, product_ids: [] }

      assert_redirected_to redeem_vendor_portal_voucher_path(@voucher.code)
      assert_equal 'Identity verification is required before redemption', flash[:alert]
    end
  end
end
