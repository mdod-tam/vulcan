# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  # Failed date-of-birth checks used to be counted in the session and reset whenever the vendor
  # reloaded the form, so the limit never applied.
  class VoucherVerificationLockoutTest < ActionDispatch::IntegrationTest
    setup do
      @constituent = create(:constituent, date_of_birth: Date.new(1980, 9, 10))
      @vendor = create(:vendor, :approved)
      @voucher = create(:voucher, :active, application: create(:application, user: @constituent), vendor: @vendor)
      Policy.stubs(:get).with('voucher_verification_max_attempts').returns(3)
      Policy.stubs(:get).with('voucher_validity_period_months').returns(6)
      sign_in_for_integration_test(@vendor)
    end

    test 'reloading the form between failures does not reset the count' do
      2.times do
        get verify_vendor_portal_voucher_path(@voucher.code)
        post_dob('10/09/1980')
        assert_redirected_to verify_vendor_portal_voucher_path(@voucher.code)
      end

      get verify_vendor_portal_voucher_path(@voucher.code)
      post_dob('10/09/1980')

      assert_redirected_to vendor_portal_vouchers_path
      assert_match(/Try again after/, flash[:alert])
    end

    test 'the form is refused during the lockout, even for the right date' do
      3.times { post_dob('10/09/1980') }

      get verify_vendor_portal_voucher_path(@voucher.code)
      assert_redirected_to vendor_portal_vouchers_path

      post_dob('09/10/1980')
      assert_redirected_to vendor_portal_vouchers_path
      assert_match(/Too many failed date of birth checks/, flash[:alert])
    end

    test 'signing out and back in does not reset the count' do
      3.times { post_dob('10/09/1980') }

      reset!
      sign_in_for_integration_test(@vendor)
      post_dob('09/10/1980')

      assert_redirected_to vendor_portal_vouchers_path
    end

    test 'each attempt is audited with its real attempt number' do
      2.times { post_dob('10/09/1980') }

      events = Event.where(action: 'voucher_verification_attempt', auditable: @voucher).order(:id)
      assert_equal([1, 2], events.map { |event| event.metadata['attempt_number'] })
      assert_equal([false, false], events.map { |event| event.metadata['locked_out'] })
    end

    test 'a correct date redirects to redemption' do
      post_dob('9/10/1980')

      assert_redirected_to redeem_vendor_portal_voucher_path(@voucher.code)
    end

    test 'an owner with no date of birth on file sends the vendor to the MAT Team' do
      @constituent.update_column(:date_of_birth, nil)

      4.times { post_dob('09/10/1980') }

      assert_redirected_to vendor_portal_vouchers_path
      assert_match(/no date of birth on file/, flash[:alert])
      assert_nil VoucherVerificationThrottle.find_by(voucher: @voucher, vendor: @vendor)
    end

    private

    def post_dob(value)
      post verify_dob_vendor_portal_voucher_path(@voucher.code), params: { date_of_birth: value }
    end
  end
end
