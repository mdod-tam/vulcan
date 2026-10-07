# frozen_string_literal: true

require 'test_helper'

module VendorPortal
  # Only a vendor who may redeem vouchers may check a constituent's date of birth or look up a
  # voucher code; otherwise the check is a date-of-birth oracle for suspended or unapproved vendors.
  class VoucherVerificationEligibilityTest < ActionDispatch::IntegrationTest
    setup do
      @constituent = create(:constituent, date_of_birth: Date.new(1980, 9, 10))
      @voucher = create(:voucher, :active, application: create(:application, user: @constituent))
    end

    {
      'a vendor awaiting approval' => -> { create(:vendor, :pending) },
      'a suspended vendor' => -> { create(:vendor, :suspended) },
      'an approved vendor whose W9 is not approved' => lambda {
        create(:vendor, :approved).tap { |vendor| vendor.update_column(:w9_status, :pending_review) }
      }
    }.each do |description, build_vendor|
      test "#{description} cannot open or submit DOB verification" do
        sign_in_for_integration_test(instance_exec(&build_vendor))

        get verify_vendor_portal_voucher_path(@voucher.code)
        assert_redirected_to vendor_portal_dashboard_path
        assert_equal 'Your account is not approved for processing vouchers yet.', flash[:alert]

        assert_no_difference -> { Event.where(action: 'voucher_verification_attempt').count } do
          post verify_dob_vendor_portal_voucher_path(@voucher.code), params: { date_of_birth: '09/10/1980' }
        end
        assert_redirected_to vendor_portal_dashboard_path
        assert_nil session[:verified_vouchers]
      end
    end

    test 'an unapproved vendor learns nothing about whether a code exists' do
      sign_in_for_integration_test(create(:vendor, :pending))

      get verify_vendor_portal_voucher_path('NO-SUCH-CODE')

      assert_redirected_to vendor_portal_dashboard_path
      assert_equal 'Your account is not approved for processing vouchers yet.', flash[:alert]
    end

    # A real code and a made-up one get the same answer on every path that takes a code.
    test 'an unapproved vendor gets the same answer for real and unknown codes everywhere' do
      sign_in_for_integration_test(create(:vendor, :pending))

      [@voucher.code, 'NO-SUCH-CODE'].each do |code|
        get vendor_portal_vouchers_path(code: code)
        assert_redirected_to vendor_portal_dashboard_path, code

        [vendor_portal_voucher_path(code), redeem_vendor_portal_voucher_path(code)].each do |path|
          get path
          assert_redirected_to vendor_portal_dashboard_path, path
        end
      end
    end

    test 'a refusal is logged with the vendor and action, never the code' do
      vendor = create(:vendor, :pending)
      sign_in_for_integration_test(vendor)
      Rails.logger.stubs(:warn)
      Rails.logger.expects(:warn).with("VendorPortal: refused vouchers#verify for vendor #{vendor.id}: not approved to process vouchers")

      get verify_vendor_portal_voucher_path(@voucher.code)
    end

    test 'an unapproved vendor still sees their voucher list, without the code form' do
      sign_in_for_integration_test(create(:vendor, :pending))

      get vendor_portal_vouchers_path

      assert_response :success
      assert_select 'form#voucher-form', count: 0
      assert_match 'Your account is not approved for processing vouchers yet.', response.body
    end

    test 'an unapproved vendor sees no Redeem link for a voucher on their list' do
      vendor = create(:vendor, :pending)
      create(:voucher, :active, vendor: vendor, application: create(:application, user: @constituent))
      sign_in_for_integration_test(vendor)

      get vendor_portal_vouchers_path

      assert_select 'a', text: 'Redeem', count: 0
      assert_match 'Cannot redeem', response.body
    end

    test 'the dashboard offers Process Voucher only to an eligible vendor' do
      sign_in_for_integration_test(create(:vendor, :pending))
      get vendor_portal_dashboard_path
      assert_select 'a', text: 'Process Voucher', count: 0
      assert_select 'span[aria-disabled=true][aria-describedby=process-voucher-unavailable]', text: 'Process Voucher'

      sign_in_for_integration_test(create(:vendor, :approved))
      get vendor_portal_dashboard_path
      assert_select 'a[href=?]', vendor_portal_vouchers_path, text: 'Process Voucher'
    end

    test 'an eligible vendor reaches verification' do
      sign_in_for_integration_test(create(:vendor, :approved))

      get verify_vendor_portal_voucher_path(@voucher.code)

      assert_response :success
    end
  end
end
