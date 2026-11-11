# frozen_string_literal: true

require 'test_helper'

module Admin
  # The application page lists what the program's vouchers bought, from completed redemption lines.
  class ApplicationPurchasedProductsTest < ActionDispatch::IntegrationTest
    setup do
      FeatureFlag.find_or_create_by!(name: 'vouchers_enabled').update!(enabled: true)
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
    end

    test 'lists each purchased product once with its latest purchase date in the program time zone' do
      application = create(:application, :approved, :voucher_fulfillment)
      phone = create(:product, name: 'Listed Phone', manufacturer: 'Acme', model_number: 'AP-1')
      record_voucher_purchase(application, phone, processed_at: Time.utc(2026, 3, 4, 12))
      # 02:00 UTC is 22:00 the previous evening in Eastern time, which is the date staff expect to see.
      record_voucher_purchase(application, phone, processed_at: Time.utc(2026, 5, 7, 2))
      create(:voucher_transaction, :pending, voucher: application.vouchers.order(:id).first)
        .voucher_transaction_products.create!(product: create(:product, name: 'Unfinished Phone'), quantity: 1)

      get admin_application_path(application)

      assert_response :success
      assert_select 'h4', text: 'Purchased Products'
      assert_select 'td', text: 'Listed Phone', count: 1
      assert_select 'td', text: 'Acme', count: 1
      assert_select 'td', text: 'AP-1', count: 1
      assert_select 'td', text: '2026-05-06', count: 1
      assert_select 'td', text: 'Unfinished Phone', count: 0
    end

    test 'shows no purchased-products section until a redemption completes' do
      application = create(:application, :approved, :voucher_fulfillment)
      create(:voucher, application: application)

      get admin_application_path(application)

      assert_response :success
      assert_select 'h4', text: 'Purchased Products', count: 0
    end
  end
end
