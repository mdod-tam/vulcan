# frozen_string_literal: true

require 'test_helper'

# An application's purchased products come from its completed redemption lines; nothing else records them.
class ApplicationPurchasedProductsTest < ActiveSupport::TestCase
  setup do
    @application = create(:application)
    @first_voucher = create(:voucher, application: @application)
    @second_voucher = create(:voucher, application: @application)
  end

  test 'purchased products are the products of completed redemptions on any of its vouchers, each listed once' do
    bought_twice = create(:product, name: 'Bought Twice')
    on_second_voucher = create(:product, name: 'On Second Voucher')
    purchase_on(@first_voucher, bought_twice)
    purchase_on(@first_voucher, bought_twice)
    purchase_on(@second_voucher, bought_twice)
    purchase_on(@second_voucher, on_second_voucher)

    assert_equal [bought_twice, on_second_voucher].sort_by(&:id), @application.purchased_products.sort_by(&:id)
    assert_equal 2, @application.purchased_products.count
  end

  test 'unfinished or non-redemption transactions and other applications\' purchases are not purchased products' do
    %i[pending failed cancelled].each do |state|
      create(:voucher_transaction, state, voucher: @first_voucher)
        .voucher_transaction_products.create!(product: create(:product), quantity: 1)
    end
    %i[refund adjustment].each do |type|
      create(:voucher_transaction, voucher: @first_voucher, transaction_type: type)
        .voucher_transaction_products.create!(product: create(:product), quantity: 1)
    end
    record_voucher_purchase(create(:application), create(:product))

    assert_empty @application.purchased_products
    assert_empty @application.purchased_products_with_dates
  end

  test 'each purchased product carries the latest completed purchase and ignores later unfinished ones' do
    bought_twice = create(:product, name: 'Bought Twice')
    once = create(:product, name: 'Bought Once')
    purchase_on(@first_voucher, bought_twice, processed_at: Time.zone.local(2026, 3, 4, 12))
    purchase_on(@second_voucher, bought_twice, processed_at: Time.zone.local(2026, 5, 6, 12))
    purchase_on(@first_voucher, once, processed_at: Time.zone.local(2026, 4, 1, 9))
    create(:voucher_transaction, :pending, voucher: @first_voucher, processed_at: Time.zone.local(2026, 6, 1, 9))
      .voucher_transaction_products.create!(product: once, quantity: 1)

    dates = @application.purchased_products_with_dates.index_with(&:last_purchased_at)

    assert_equal [bought_twice, once].sort_by(&:id), dates.keys.sort_by(&:id)
    assert_equal Time.zone.local(2026, 5, 6, 12), dates.fetch(bought_twice)
    assert_equal Time.zone.local(2026, 4, 1, 9), dates.fetch(once)
  end

  private

  def purchase_on(voucher, product, processed_at: Time.current)
    create(:voucher_transaction, voucher: voucher, processed_at: processed_at)
      .voucher_transaction_products.create!(product: product, quantity: 1)
  end
end
