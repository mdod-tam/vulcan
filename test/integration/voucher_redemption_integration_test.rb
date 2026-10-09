# frozen_string_literal: true

require 'test_helper'

class VoucherRedemptionIntegrationTest < ActionDispatch::IntegrationTest
  def setup
    Policy.stubs(:voucher_minimum_redemption_amount).returns(10.0)

    # Fully eligible: approved, with an approved W9 on file.
    @vendor = create(:vendor, :approved)

    @constituent = User.create!(
      first_name: 'Integration',
      last_name: 'Tester',
      date_of_birth: Date.new(1980, 1, 15),
      type: 'Users::Constituent',
      email: "integration_test.#{SecureRandom.hex(4)}@example.com",
      password: 'password1234',
      password_confirmation: 'password1234',
      phone: "555-#{rand(100..999)}-#{rand(1000..9999)}" # Phone must be unique
    )

    @constituent.update!(
      vision_disability: true,
      hearing_disability: true,
      mobility_disability: true,
      cognition_disability: false,
      speech_disability: false,
      date_of_birth: Date.new(1985, 1, 1)
    )

    @application = create(:application,
                          user: @constituent,
                          status: 'draft',
                          household_size: 2,
                          annual_income: 35_000,
                          medical_provider_name: 'Dr. Integration Test',
                          medical_provider_email: "doctor.integration.#{SecureRandom.hex(4)}@example.com",
                          medical_provider_phone: "555-#{rand(100..999)}-#{rand(1000..9999)}")

    @voucher = Voucher.create!(
      application: @application,
      initial_value: 100.00,
      remaining_value: 100.00,
      issued_at: Time.current,
      status: 'active'
    )

    @product1 = Product.create!(
      name: 'Integration Test Product 1',
      manufacturer: 'Integration Test Manufacturer',
      model_number: "ITP-1-#{SecureRandom.hex(4)}",
      device_types: ['Smartphone'],
      price: 25.0,
      description: 'A product for integration testing'
    )

    @product2 = Product.create!(
      name: 'Integration Test Product 2',
      manufacturer: 'Integration Test Manufacturer',
      model_number: "ITP-2-#{SecureRandom.hex(4)}",
      device_types: ['Tablet'],
      price: 40.0,
      description: 'Another product for integration testing'
    )

    sign_in_for_integration_test(@vendor)

    # Verify identity so that the session holds this voucher.
    post verify_dob_vendor_portal_voucher_path(@voucher.code), params: {
      date_of_birth: @constituent.date_of_birth.strftime('%Y-%m-%d')
    }

    FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = true }
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: true)
  end

  # Real prerequisites, real requests: every record below is written by the redemption itself.
  test 'an eligible vendor redeems part of a voucher, then the rest' do
    get verify_vendor_portal_voucher_path(@voucher.code)
    assert_response :success
    post verify_dob_vendor_portal_voucher_path(@voucher.code), params: { date_of_birth: '01/01/1985' }
    assert_redirected_to redeem_vendor_portal_voucher_path(@voucher.code)

    redeem(65, @product1, @product2)
    assert_redirected_to vendor_portal_dashboard_path

    first = @voucher.transactions.order(:id).last
    assert_completed_redemption(first, amount: '65.00', products: [@product1, @product2])
    @voucher.reload
    assert_equal BigDecimal('35.00'), @voucher.remaining_value
    assert_equal 'active', @voucher.status
    assert_equal @vendor.id, @voucher.vendor_id
    assert_includes @application.reload.products, @product1
    assert_includes @application.products, @product2

    redeem(35, @product1)
    assert_redirected_to vendor_portal_dashboard_path

    second = @voucher.transactions.order(:id).last
    assert_not_equal first, second
    assert_completed_redemption(second, amount: '35.00', products: [@product1])
    @voucher.reload
    assert_equal BigDecimal('0.00'), @voucher.remaining_value
    assert_equal 'redeemed', @voucher.status
  end

  # The vendor verifies while eligible, then loses eligibility before redeeming.
  {
    'W9 removed' => ->(vendor) { vendor.w9_form.purge },
    'W9 back in review' => ->(vendor) { vendor.update_column(:w9_status, :pending_review) },
    'W9 rejected' => ->(vendor) { vendor.update_column(:w9_status, :rejected) },
    'vendor approval pending' => ->(vendor) { vendor.update_column(:vendor_authorization_status, :pending) },
    'vendor suspended' => ->(vendor) { vendor.update_column(:vendor_authorization_status, :suspended) }
  }.each do |description, revoke|
    test "a redemption after #{description} is refused and writes nothing" do
      revoke.call(@vendor)

      assert_no_difference(['VoucherTransaction.count', 'VoucherTransactionProduct.count', 'Event.count']) do
        redeem(25, @product1)
      end

      assert_redirected_to vendor_portal_dashboard_path
      assert_equal 'Your account is not approved for processing vouchers yet.', flash[:alert]
      @voucher.reload
      assert_equal BigDecimal('100.00'), @voucher.remaining_value
      assert_nil @voucher.vendor_id
      assert_empty @application.reload.products
    end
  end

  test 'voucher verification handles invalid codes appropriately' do
    get vendor_portal_vouchers_path(code: 'INVALIDVOUCHERCODE')
    assert_response :success
    assert_match(/Invalid voucher code/, flash[:alert])
  end

  test 'voucher redemption handles validation errors appropriately' do
    # A new session has no verified vouchers.
    reset!
    sign_in_for_integration_test(@vendor)

    post process_redemption_vendor_portal_voucher_path(@voucher.code), params: {
      amount: 150.0,
      product_ids: [@product1.id],
      product_quantities: { @product1.id.to_s => '1' }
    }

    assert_redirected_to verify_vendor_portal_voucher_path(@voucher.code)
    follow_redirect!
    assert_match(/Identity verification is required before redemption/,
                 flash[:alert])
  end

  test 'voucher redemption returns error when vouchers_enabled feature flag is false' do
    FeatureFlag.find_by(name: 'vouchers_enabled').update(enabled: false)

    post process_redemption_vendor_portal_voucher_path(@voucher.code), params: {
      amount: 150.0,
      product_ids: [@product1.id],
      product_quantities: { @product1.id.to_s => '1' }
    }

    assert_response :unprocessable_content
    assert_select 'body', text: /Voucher functionality is currently disabled/
  end

  test 'a corrected retry and a resubmitted form record one purchase' do
    submission_id = open_redeem_form

    redeem('65.005', @product1, submission_id: submission_id)
    assert_response :unprocessable_content
    assert_select 'input[name="submission_id"][value=?]', submission_id, visible: :all
    assert_select 'input[name="amount"][value="65.005"]'
    assert_select "input[name='product_ids[]'][value='#{@product1.id}'][checked]"

    redeem('65.00', @product1, submission_id: submission_id)
    assert_redirected_to vendor_portal_dashboard_path
    # The browser's back button or a network retry sends the same form again.
    redeem('65.00', @product1, submission_id: submission_id)
    assert_redirected_to vendor_portal_dashboard_path

    assert_equal 1, @voucher.transactions.count
    assert_equal BigDecimal('35.00'), @voucher.reload.remaining_value
    assert_not_equal submission_id, open_redeem_form, 'opening the form again starts a new purchase'
  end

  private

  # The redeem form submits one of each selected product.
  # Each redemption starts from the form, which carries its submission ID. A vendor who can no longer
  # open it sends the ID of a form opened earlier.
  def open_redeem_form
    get redeem_vendor_portal_voucher_path(@voucher.code)
    css_select('input[name="submission_id"]').first&.[]('value') || SecureRandom.uuid
  end

  def redeem(amount, *products, submission_id: open_redeem_form)
    post process_redemption_vendor_portal_voucher_path(@voucher.code), params: {
      submission_id: submission_id,
      amount: amount,
      product_ids: products.map(&:id),
      product_quantities: products.to_h { |product| [product.id.to_s, '1'] }
    }
  end

  def assert_completed_redemption(transaction, amount:, products:)
    assert_equal @vendor.id, transaction.vendor_id
    assert_equal 'redemption', transaction.transaction_type
    assert_equal 'transaction_completed', transaction.status
    assert_equal BigDecimal(amount), transaction.amount
    assert_equal products.map(&:id).sort, transaction.voucher_transaction_products.pluck(:product_id).sort
    assert_equal [1], transaction.voucher_transaction_products.pluck(:quantity).uniq
  end
end
