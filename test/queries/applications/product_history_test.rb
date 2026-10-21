# frozen_string_literal: true

require 'test_helper'

module Applications
  class ProductHistoryTest < ActiveSupport::TestCase
    test 'completed redemption lines and active shipped equipment establish exact product history' do
      application = create(:application, :approved, :with_all_proofs)
      purchased = create(:product, :archived)
      shipped = create(:product)
      voucher = create(:voucher, application: application)
      purchase = create(:voucher_transaction, voucher: voucher, processed_at: 2.days.ago)
      2.times { purchase.voucher_transaction_products.create!(product: purchased, quantity: 1) }
      create(:equipment_item, application: application, product: purchased, shipped_at: Date.current, tracking_number: 'shared-product')
      create(:equipment_item, application: application, product: shipped, shipped_at: Date.current, tracking_number: 'shipped-product')
      create(:equipment_item, application: application, product: create(:product))
      create(:equipment_item, application: application, purchase_order: nil, withdrawn_at: Time.current)
      %i[pending failed cancelled].each do |state|
        transaction = create(:voucher_transaction, state, voucher: voucher)
        transaction.voucher_transaction_products.create!(product: create(:product), quantity: 1)
      end
      %i[refund adjustment].each do |type|
        transaction = create(:voucher_transaction, voucher: voucher, transaction_type: type)
        transaction.voucher_transaction_products.create!(product: create(:product), quantity: 1)
      end
      application.products << create(:product)
      create(:training_session, application: application, product_trained_on: create(:product))

      history = Applications::ProductHistory.new(applications: Application.where(id: application.id))
      assert_empty application.user.products
      assert_equal [purchased.id, shipped.id].sort, history.products.map(&:id).sort
      entry = history.groups.sole.entries.find { |each| each.product == purchased }
      assert_equal %i[voucher_purchase program_shipment], entry.sources.map(&:kind)
      assert_equal [purchase.processed_at.to_date, Date.current], entry.sources.map(&:occurred_on)
    end

    test 'archived applications remain accessible and beneficiaries stay grouped within the supplied authorization' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      own = create(:application, :archived, user: guardian)
      managed = create(:application, :approved, :with_all_proofs, user: dependent, managing_guardian: guardian)
      unrelated = create(:application, :approved, :with_all_proofs)
      [own, managed, unrelated].each do |application|
        create(:equipment_item, application: application, shipped_at: Date.current, tracking_number: 'shipment')
      end

      history = Applications::ProductHistory.new(applications: Application.accessible_by(guardian))
      assert_equal [guardian.id, dependent.id].sort, history.groups.map { |group| group.beneficiary.id }.sort
      assert_equal 2, history.products.length
      assert_raises(ActiveRecord::RecordNotFound) { history.find_product!(unrelated.equipment_items.sole.product_id) }
      assert_equal [], Applications::ProductHistory.new(applications: Application.none).products
    end
  end
end
