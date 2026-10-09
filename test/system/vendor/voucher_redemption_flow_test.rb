# frozen_string_literal: true

require 'application_system_test_case'

module VendorPortal
  class VoucherRedemptionFlowTest < ApplicationSystemTestCase
    include SystemTestAuthentication

    def setup
      # The shared test setup leaves the voucher workflow off; redemption requires it.
      FeatureFlag.enable!(:vouchers_enabled)
      @vendor = create(:vendor, :approved)

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

      @application = create(:application,
                            user: @constituent,
                            status: 'in_progress',
                            household_size: 1,
                            annual_income: 25_000,
                            medical_provider_name: 'Dr. Test Provider',
                            medical_provider_email: 'doctor@example.com',
                            medical_provider_phone: '555-123-4567')

      @voucher = create(:voucher,
                        application: @application,
                        initial_value: 100.00,
                        remaining_value: 100.00,
                        code: 'TESTVOUCHER123',
                        issued_at: Time.current,
                        status: 'active')

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

    test 'vendor redeems voucher through the UI flow' do
      sign_in_as_vendor

      # The redeem page redirects to identity verification first.
      visit redeem_vendor_portal_voucher_path(@voucher.code)

      assert_text 'Identity Verification'
      assert_text @voucher.code

      find_field('date_of_birth').set(@constituent.date_of_birth.strftime('%m/%d/%Y'))
      click_button 'Verify Identity'

      assert_text 'Identity verification successful.'

      assert_text 'Voucher Redemption'
      assert_text @voucher.code

      # Partial redemption
      find_field('redemption-amount').set('50.0')

      check "product_#{@product1.id}"

      submit_button = find_by_id('submit-redemption')
      assert_not submit_button.disabled?, 'Submit button should be enabled when products are selected'

      click_button 'Process Redemption'

      assert_text 'Voucher successfully processed'

      @voucher.reload
      @application.reload
      assert_equal 50.0, @voucher.remaining_value, 'Voucher remaining value should be reduced by redemption amount'
      assert_includes @application.products, @product1, 'Product should be associated with application'
    end

    test 'vendor can verify a valid voucher code' do
      sign_in_as_vendor
      visit vendor_portal_vouchers_path

      find_field('voucher_code').set(@voucher.code)
      click_button 'Verify Voucher'

      assert_current_path verify_vendor_portal_voucher_path(@voucher.code)
      assert_text 'Identity Verification'
    end

    test 'vendor sees error when verifying an invalid voucher code' do
      sign_in_as_vendor
      visit vendor_portal_vouchers_path

      find_field('voucher_code').set(@invalid_voucher_code)
      click_button 'Verify Voucher'

      assert_text 'Invalid voucher code'
      assert_current_path vendor_portal_vouchers_path(code: @invalid_voucher_code)
    end

    test 'vendor can select multiple products with different quantities' do
      sign_in_as_vendor
      visit redeem_vendor_portal_voucher_path(@voucher.code)

      assert_text 'Identity Verification'
      find_field('date_of_birth').set(@constituent.date_of_birth.strftime('%m/%d/%Y'))
      click_button 'Verify Identity'

      assert_text 'Identity verification successful.'

      assert_text 'Voucher Redemption'

      check "product_#{@product1.id}"
      check "product_#{@product2.id}"

      # The form does not collect quantities, so each product counts once.
      expected_total = @product1.price + @product2.price

      find_field('redemption-amount').set(expected_total.to_s)

      click_button 'Process Redemption'
      assert_text 'Voucher successfully processed'

      @application.reload
      assert_includes @application.products, @product1
      assert_includes @application.products, @product2

      @voucher.reload
      assert_equal 100.0 - expected_total, @voucher.remaining_value
    end

    test 'vendor cannot submit redemption without selecting products' do
      sign_in_as_vendor
      visit redeem_vendor_portal_voucher_path(@voucher.code)

      assert_text 'Identity Verification'
      find_field('date_of_birth').set(@constituent.date_of_birth.strftime('%m/%d/%Y'))
      click_button 'Verify Identity'

      assert_text 'Identity verification successful.'
      assert_text 'Voucher Redemption'

      find_field('redemption-amount').set('50.0')

      # form.submit() skips the JavaScript submit guard, so this tests the server-side validation.
      page.execute_script("document.getElementById('redemption-form').submit()")

      assert_text 'Please select at least one product for this voucher redemption'
      assert_current_path process_redemption_vendor_portal_voucher_path(@voucher.code)

      @voucher.reload
      assert_equal 100.0, @voucher.remaining_value
    end

    test 'vendor cannot redeem more than voucher balance' do
      sign_in_as_vendor
      visit redeem_vendor_portal_voucher_path(@voucher.code)

      assert_text 'Identity Verification'
      find_field('date_of_birth').set(@constituent.date_of_birth.strftime('%m/%d/%Y'))
      click_button 'Verify Identity'

      assert_text 'Identity verification successful.'
      assert_text 'Voucher Redemption'

      find_field('redemption-amount').set('150.0')
      check "product_#{@product1.id}"

      # form.submit() skips HTML5 validation and the JavaScript submit guard.
      page.execute_script("document.getElementById('redemption-form').submit()")

      # The full message also includes the formatted balance.
      assert_text 'Cannot redeem more than the available amount'
      assert_current_path process_redemption_vendor_portal_voucher_path(@voucher.code)

      @voucher.reload
      assert_equal 100.0, @voucher.remaining_value
    end

    private

    def sign_in_as_vendor
      system_test_sign_in(@vendor)

      visit vendor_portal_dashboard_path
      assert_text 'Vendor Dashboard'
    end
  end
end
