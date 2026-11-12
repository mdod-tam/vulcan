# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class VoucherLifecycleTest < ApplicationSystemTestCase
    include SystemTestAuthentication

    def setup
      # The shared test setup leaves the voucher workflow off; redemption requires it.
      FeatureFlag.enable!(:vouchers_enabled)
      @vendor = create(:vendor, :approved)
      @admin = create(:admin)
      %w[hearing vision].each do |disability|
        Policy.find_or_initialize_by(key: "voucher_value_#{disability}_disability").update!(value: 50, updated_by: @admin)
      end

      @constituent = create(:constituent,
                            first_name: 'Alice',
                            last_name: 'Wonder',
                            email: 'alice@example.com',
                            date_of_birth: 25.years.ago.to_date,
                            vision_disability: true,
                            hearing_disability: true,
                            mobility_disability: false,
                            cognition_disability: false,
                            speech_disability: false)

      # Application approval is fixture setup; voucher issuance below is a real staff action.
      @application = create(:application, :completed,
                            user: @constituent,
                            household_size: 1,
                            annual_income: 25_000,
                            certifying_professional_name: 'Dr. Test Provider',
                            certifying_professional_email: 'doctor@example.com',
                            certifying_professional_phone: '555-123-4567')

      @product1 = create(:product,
                         name: 'System Test Product 1',
                         manufacturer: 'Test Manufacturer',
                         model_number: 'STP-1',
                         device_types: ['Tablet'],
                         price: 20.0,
                         description: 'A product for system testing')

      @product2 = create(:product,
                         name: 'System Test Product 2',
                         manufacturer: 'Test Manufacturer',
                         model_number: 'STP-2',
                         device_types: ['Smartphone'],
                         price: 35.0,
                         description: 'Another product for system testing')

      @invalid_voucher_code = 'INVALIDCODE12345'
    end

    test 'staff issue a voucher and vendor recovers rejected redemptions into partial and final purchases' do
      assert_empty @application.vouchers
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit admin_application_path(@application)
      assert_difference('Voucher.count', 1) do
        accept_confirm { click_button 'Assign Voucher' }
        assert_text 'Voucher assigned successfully'
      end
      @voucher = @application.vouchers.sole
      assert @voucher.voucher_active?
      assert_equal 100, @voucher.initial_value
      assert_equal 100, @voucher.remaining_value
      assert @voucher.issued_at.present?
      assert_equal @admin.id, @voucher.events.where(action: 'voucher_assigned').sole.user_id
      assert_no_button 'Assign Voucher'
      system_test_switch_user(@vendor, bypass_mfa_enrollment: true)
      click_link 'Vouchers'
      fill_in 'Voucher Code', with: @invalid_voucher_code
      click_button 'Verify Voucher'
      assert_text 'Invalid voucher code'
      assert_current_path vendor_portal_vouchers_path(code: @invalid_voucher_code)

      open_voucher_redemption(@voucher, date_of_birth: @constituent.date_of_birth)
      assert_button 'Process Redemption', disabled: true
      fill_in 'Redemption Amount', with: '50.00'

      # Bypass the browser guard once to retain the server's empty-selection contract.
      page.execute_script("document.getElementById('redemption-form').submit()")
      assert_text 'Please select at least one product for this voucher redemption'
      assert_current_path process_redemption_vendor_portal_voucher_path(@voucher.code)
      assert_equal 100, @voucher.reload.remaining_value
      assert_empty @vendor.voucher_transactions

      check "product_#{@product1.id}"
      fill_in 'Redemption Amount', with: '150.00'
      page.execute_script("document.getElementById('redemption-form').submit()")
      assert_text 'Cannot redeem more than the available amount'
      assert_equal 100, @voucher.reload.remaining_value
      assert_empty @vendor.voucher_transactions

      check "product_#{@product2.id}"
      expected_total = @product1.price + @product2.price
      fill_in 'Redemption Amount', with: expected_total.to_s
      assert_button 'Process Redemption', disabled: false
      click_button 'Process Redemption'
      assert_text 'Voucher successfully processed'
      purchase = @vendor.voucher_transactions.sole
      assert_equal [@product1.id, @product2.id].sort, purchase.products.pluck(:id).sort
      assert_equal [@product1.id, @product2.id].sort, @application.purchased_products.pluck(:id).sort
      assert_equal 100 - expected_total, @voucher.reload.remaining_value
      take_screenshot('voucher-lifecycle-partial-purchase', html: true, full: true)

      # A second purchase uses the remaining balance and a new submission from the form.
      visit redeem_vendor_portal_voucher_path(@voucher.code)
      assert_text 'Voucher Redemption'
      check "product_#{@product1.id}"
      fill_in 'Redemption Amount', with: @voucher.remaining_value.to_s
      click_button 'Process Redemption'
      assert_text 'Voucher successfully processed'
      assert_equal 2, @vendor.voucher_transactions.count
      assert_equal 0, @voucher.reload.remaining_value
      assert @voucher.voucher_redeemed?
      take_screenshot('voucher-lifecycle-redeemed', html: true, full: true)
    end
  end
end
