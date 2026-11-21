# frozen_string_literal: true

require 'test_helper'
require 'active_record/testing/query_assertions'

module Equipment
  class NavigationSummaryTest < ActiveSupport::TestCase
    include ActiveRecord::Assertions::QueryAssertions

    setup { FeatureFlag.disable!(:vouchers_enabled) }

    test 'requests count unreserved rows rather than units and retain unknown waits' do
      oldest = 5.days.ago.change(usec: 0)
      partial = create(:equipment_need, remaining_quantity: 5, unfulfilled_since: oldest)
      full = create(:equipment_need, remaining_quantity: 2, unfulfilled_since: 20.days.ago)
      reserved_item = create(:equipment_item, purchase_order: nil, unfulfilled_since: 30.days.ago)
      create(:equipment_item, purchase_order: nil, unfulfilled_since: nil)
      create(:equipment_need, remaining_quantity: 0, unfulfilled_since: 40.days.ago)
      create(:equipment_need, application: create(:application, :archived), unfulfilled_since: 50.days.ago)
      Bidding.new(actor: create(:admin)).create!(number: 'SUMMARY-RESERVATIONS', needs: [
                                                   { id: partial.id, quantity: 3, lock_version: partial.lock_version },
                                                   { id: full.id, quantity: 2, lock_version: full.lock_version }
                                                 ], items: [{ id: reserved_item.id, lock_version: reserved_item.lock_version }])

      summary = NavigationSummary.new
      expected_name = partial.application.user.full_name
      assert_equal NavigationSummary::Metric.new(count: 2, oldest_at: oldest, unknown_dates: 1, oldest_application: partial.application,
                                                 oldest_record: partial, products: [partial.product], additional_constituents: 0), summary.requests
      assert_no_queries do
        assert_equal expected_name, summary.requests.oldest_application.user.full_name
        assert_equal [partial.product.model_number], summary.requests.products.map(&:model_number)
      end
    end

    test 'shipments use sent and allocation clocks independently of application procurement eligibility' do
      sent_on = 4.days.ago.to_date
      oldest_item = create(:equipment_item, purchase_order: create(:purchase_order, sent_at: sent_on), po_assigned_at: 20.days.ago)
      create(:equipment_item, application: create(:application, :archived), purchase_order: create(:purchase_order, sent_at: 3.days.ago.to_date))
      existing_stock(product: create(:product), application: create(:application, :approved, :with_all_proofs), stock_allocated_at: 2.days.ago)
      create(:equipment_item, purchase_order: create(:purchase_order, sent_at: nil))
      create(:equipment_item, shipped_at: Date.current, tracking_number: 'ALREADY-SHIPPED')
      existing_stock(product: create(:product))

      summary = NavigationSummary.new
      expected_name = oldest_item.application.user.full_name
      assert_equal NavigationSummary::Metric.new(count: 3, oldest_at: sent_on.to_time, unknown_dates: 0,
                                                 oldest_application: oldest_item.application, oldest_record: oldest_item,
                                                 products: [oldest_item.product], additional_constituents: 0), summary.shipments
      assert_no_queries do
        assert_equal expected_name, summary.shipments.oldest_application.user.full_name
        assert_equal [oldest_item.product.model_number], summary.shipments.products.map(&:model_number)
      end
    end

    test 'the oldest detached request and allocated stock link to their own constituent' do
      request_started_at = 3.weeks.ago.change(usec: 0)
      detached = create(:equipment_item, purchase_order: nil, unfulfilled_since: request_started_at)
      create(:equipment_need, unfulfilled_since: 1.week.ago)
      allocation_started_at = 2.weeks.ago.change(usec: 0)
      allocated = existing_stock(product: create(:product), application: create(:application, :approved, :with_all_proofs),
                                 stock_allocated_at: allocation_started_at)
      create(:equipment_item, purchase_order: create(:purchase_order, sent_at: 1.week.ago.to_date))
      summary = NavigationSummary.new
      request_name = detached.application.user.full_name
      shipment_name = allocated.application.user.full_name

      assert_equal detached.application, summary.requests.oldest_application
      assert_equal request_started_at, summary.requests.oldest_at
      assert_equal allocated.application, summary.shipments.oldest_application
      assert_equal allocation_started_at, summary.shipments.oldest_at
      assert_no_queries do
        assert_equal request_name, summary.requests.oldest_application.user.full_name
        assert_equal shipment_name, summary.shipments.oldest_application.user.full_name
      end
    end

    test 'unknown waits do not invent an oldest constituent or date' do
      create(:equipment_need, unfulfilled_since: nil)
      summary = NavigationSummary.new

      assert_equal NavigationSummary::Metric.new(count: 1, oldest_at: nil, unknown_dates: 1, oldest_application: nil,
                                                 oldest_record: nil, products: [], additional_constituents: 0), summary.requests
      assert_equal NavigationSummary::Metric.new(count: 0, oldest_at: nil, unknown_dates: 0, oldest_application: nil,
                                                 oldest_record: nil, products: [], additional_constituents: 0), summary.shipments
    end

    test 'bids and ready purchase orders count records and preserve their own oldest clocks' do
      bid_opened = 3.weeks.ago.change(usec: 0)
      product = create(:product)
      old_bid = BidGroup.create!(number: 'SUMMARY-OPEN-OLD', purpose: 'program_stock', created_at: bid_opened, membership_changed_at: 1.day.ago)
      [old_bid, BidGroup.create!(number: 'SUMMARY-OPEN-NEW', purpose: 'program_stock', created_at: 1.week.ago)].each do |bid|
        bid.bid_group_lines.create!(product: product, quantity: 1)
      end
      BidGroup.create!(number: 'SUMMARY-EMPTY-OPEN', created_at: 30.weeks.ago)
      BidGroup.create!(number: 'SUMMARY-CANCELLED', created_at: 10.weeks.ago, cancelled_at: Time.current)
      assigned_at = 5.days.ago.change(usec: 0)
      order = create(:purchase_order, sent_at: nil, created_at: 6.months.ago)
      oldest_item = create(:equipment_item, purchase_order: order, po_assigned_at: assigned_at)
      create(:equipment_item, purchase_order: order, po_assigned_at: 2.days.ago)
      unknown = create(:purchase_order, sent_at: nil)
      create(:equipment_item, purchase_order: unknown, po_assigned_at: 10.days.ago)
      create(:equipment_item, purchase_order: unknown, po_assigned_at: nil)
      create(:purchase_order, sent_at: nil)
      create(:equipment_item, po_assigned_at: 30.days.ago)
      BidGroup.create!(number: 'SUMMARY-AWARDED', purchase_order: order, created_at: 20.weeks.ago)
      summary = NavigationSummary.new
      expected_name = oldest_item.application.user.full_name

      assert_equal NavigationSummary::Metric.new(count: 2, oldest_at: bid_opened, unknown_dates: 0, oldest_application: nil,
                                                 oldest_record: old_bid, products: [product], additional_constituents: 0), summary.bids
      assert_equal NavigationSummary::Metric.new(count: 2, oldest_at: assigned_at, unknown_dates: 1, oldest_application: oldest_item.application,
                                                 oldest_record: order, products: [oldest_item.product], additional_constituents: 1), summary.purchase_orders
      assert_no_queries do
        assert_equal [product.model_number], summary.bids.products.map(&:model_number)
        assert_equal [oldest_item.product.model_number], summary.purchase_orders.products.map(&:model_number)
        assert_equal expected_name, summary.purchase_orders.oldest_application.user.full_name
      end
    end

    test 'bid context represents its oldest current application without attributing other constituents devices to it' do
      historical = create(:application, :archived)
      representative = create(:application, :approved, :with_all_proofs, user: historical.user, application_date: Date.current)
      tablet = create(:product, model_number: 'iPad Pro 13-inch')
      first = create(:equipment_need, application: representative, product: tablet)
      repeated_constituent = create(:equipment_need, application: historical)
      other = create(:equipment_need)
      released = create(:equipment_need)
      opened_at = 4.weeks.ago.change(usec: 0)
      bid = BidGroup.create!(number: 'SUMMARY-MIXED-CONTEXT', created_at: opened_at, membership_changed_at: Time.current)
      members = [[released, 5.weeks.ago, Time.current], [first, 3.weeks.ago, nil], [repeated_constituent, 2.weeks.ago, nil], [other, 1.week.ago, nil]]
      members.each do |need, created_at, released_at|
        bid.bid_group_lines.create!(equipment_need: need, product: need.product, quantity: 1, created_at:, released_at:)
      end
      summary = NavigationSummary.new.bids

      assert_equal 1, summary.count
      assert_equal opened_at, summary.oldest_at
      assert_equal bid, summary.oldest_record
      assert_equal representative, summary.oldest_application
      assert_equal [tablet], summary.products
      assert_equal 1, summary.additional_constituents, 'Another application for the same person is not another constituent'
      expected_name = representative.user.full_name
      assert_no_queries do
        assert_equal expected_name, summary.oldest_application.user.full_name
        assert_equal ['iPad Pro 13-inch'], summary.products.map(&:model_number)
      end
    end

    test 'unsent stock orders retain stock context and withdrawn units do not erase their recorded wait' do
      product = create(:product, model_number: 'iPhone 17 Pro Max')
      order = purchased_stock(product:, quantity: 2, sent_at: nil)
      active, withdrawn = order.equipment_items.order(:id).to_a
      assigned_at = 1.week.ago.change(usec: 0)
      active.update!(po_assigned_at: assigned_at)
      withdrawn.update!(po_assigned_at: nil, withdrawn_at: Time.current)
      summary = NavigationSummary.new.purchase_orders

      assert_equal NavigationSummary::Metric.new(count: 1, oldest_at: assigned_at, unknown_dates: 0, oldest_application: nil,
                                                 oldest_record: order, products: [product], additional_constituents: 0), summary
      active.update!(po_assigned_at: nil)
      assert_equal NavigationSummary::Metric.new(count: 1, oldest_at: nil, unknown_dates: 1, oldest_application: nil,
                                                 oldest_record: nil, products: [], additional_constituents: 0), NavigationSummary.new.purchase_orders
    end

    test 'inventory hashes and totals follow received allocation sent and withdrawal facts' do
      product = create(:product)
      other = create(:product)
      existing_stock(product:)
      existing_stock(product: other)
      existing_stock(product:, application: create(:application, :approved, :with_all_proofs), stock_allocated_at: 2.days.ago)
      existing_stock(product:, withdrawn_at: Time.current)
      existing_stock(product:, application: create(:application, :approved, :with_all_proofs), stock_allocated_at: 2.days.ago,
                     shipped_at: Date.current, tracking_number: 'STOCK-SHIPPED', setup_confirmed_at: Time.current)
      purchased_stock(product:, quantity: 2, sent_at: 2.days.ago.to_date)
      purchased_stock(product:, quantity: 1, sent_at: nil)
      create(:equipment_item, product:)
      summary = NavigationSummary.new

      assert_equal({ product.id => 1, other.id => 1 }, summary.available_counts)
      assert_equal({ product.id => 1 }, summary.reserved_counts)
      assert_equal({ product.id => 2 }, summary.incoming_counts)
      assert_equal({ available: 2, reserved: 1, incoming: 2 }, summary.stock_counts)
    end

    test 'metrics and inventory counts are memoized within one summary instance' do
      summary = NavigationSummary.new
      methods = %i[requests shipments bids purchase_orders available_counts reserved_counts incoming_counts stock_counts]
      cached = methods.index_with { |method| summary.public_send(method) }
      create(:equipment_need)

      assert_no_queries do
        cached.each { |method, value| assert_same value, summary.public_send(method) }
      end
      assert_equal cached.fetch(:requests).count + 1, NavigationSummary.new.requests.count
    end

    private

    def existing_stock(product:, **attributes)
      create(:equipment_item, { product:, application: nil, fulfillment_source: 'existing_stock', purchase_order: nil,
                                stock_received_on: 30.days.ago.to_date, intake_provenance: 'Verified summary stock' }.merge(attributes))
    end

    def purchased_stock(product:, quantity:, sent_at:)
      order = create(:purchase_order, purpose: 'program_stock', sent_at:)
      group = BidGroup.create!(number: "SUMMARY-STOCK-#{order.id}", purpose: 'program_stock', purchase_order: order)
      line = group.bid_group_lines.create!(product:, quantity:)
      quantity.times do
        create(:equipment_item, product:, application: nil, fulfillment_source: 'program_stock_po', purchase_order: order, acquisition_bid_group_line: line)
      end
      order
    end
  end
end
