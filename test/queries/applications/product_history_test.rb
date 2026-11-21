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
      create(:training_session, application: application, product_trained_on: create(:product))

      history = Applications::ProductHistory.new(applications: Application.where(id: application.id))
      assert_equal [purchased.id, shipped.id].sort, history.products.map(&:id).sort
      entry = history.groups.sole.entries.find { |each| each.product == purchased }
      assert_equal %i[voucher_purchase voucher_purchase program_shipment], entry.sources.map(&:status)
      assert_equal [purchase.processed_at.to_date, purchase.processed_at.to_date, Date.current], entry.sources.map(&:occurred_on)
      assert_equal 3, entry.sources.sum(&:quantity)
      assert_equal 3, entry.sources.map(&:identity).uniq.length
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

    test 'portal visibility includes sent and allocated units while fulfilled history remains shipped only' do
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment)
      product = create(:product)
      sent = create(:equipment_item, application:, product:)
      shipped = create(:equipment_item, application:, product:, shipped_at: Date.current, tracking_number: 'SHIPPED')
      stock = create(:equipment_item, application:, product:, purchase_order: nil, fulfillment_source: 'existing_stock',
                                      stock_received_on: 5.days.ago.to_date, stock_allocated_at: Time.current, intake_provenance: 'Verified shelf stock')
      unsent = create(:equipment_item, application:, purchase_order: create(:purchase_order, sent_at: nil))
      create(:equipment_item, application: nil, product:, purchase_order: nil, fulfillment_source: 'existing_stock',
                              stock_received_on: Date.current, intake_provenance: 'Verified unallocated stock')
      relation = Application.where(id: application.id)

      history = ProductHistory.new(applications: relation, mode: :portal_visible)
      entry = history.groups.sole.entries.sole
      assert_equal product, entry.product
      assert_equal [sent.id, shipped.id, stock.id].sort, entry.sources.map { |source| source.identity.delete_prefix('equipment:').to_i }.sort
      assert_equal %i[program_shipment order_in_progress stock_preparation], entry.sources.map(&:status)
      assert_equal [Date.current, nil, nil], entry.sources.map(&:occurred_on)
      assert_equal 3, entry.sources.sum(&:quantity)
      assert_raises(ActiveRecord::RecordNotFound) { history.find_product!(unsent.product_id) }
      assert_equal ["equipment:#{shipped.id}"], ProductHistory.new(applications: relation).groups.sole.entries.sole.sources.map(&:identity)
    end

    test 'cancelled demand does not promise fulfillment and released stock loses guidance authorization' do
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                                      equipment_needs_initialized_at: Time.current, equipment_needs_decided_at: Time.current)
      product = create(:product)
      item = create(:equipment_item, application:, product:, purchase_order: nil, withdrawn_at: Time.current)
      history = ProductHistory.new(applications: Application.where(id: application.id), mode: :portal_visible)
      assert_empty history.products
      assert_not history.fulfillment_in_progress?
      create(:equipment_need, application:, product:, remaining_quantity: 1)
      assert ProductHistory.new(applications: Application.where(id: application.id), mode: :portal_visible).fulfillment_in_progress?
      assert_raises(ActiveRecord::RecordNotFound) { history.find_product!(item.product_id) }
    end
  end
end
