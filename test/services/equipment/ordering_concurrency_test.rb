# frozen_string_literal: true

require 'test_helper'

module Equipment
  class OrderingConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @product = create(:product)
      @first_need = create(:equipment_need, product: @product)
      @second_need = create(:equipment_need, product: @product)
      @prefix = "CONCURRENT-#{SecureRandom.hex(5)}"
    end

    teardown do
      needs = [@first_need, @second_need].compact
      users = [@admin, *needs.map { |need| need.application.user }].compact
      Event.where(user_id: @admin.id).delete_all if @admin
      units = EquipmentItem.where(product_id: @product&.id)
      order_ids = units.pluck(:purchase_order_id).compact
      lines = BidGroupLine.where(product_id: @product&.id)
      group_ids = lines.pluck(:bid_group_id)
      units.delete_all
      lines.delete_all
      BidGroup.where(id: group_ids).delete_all
      PurchaseOrder.where(id: order_ids).delete_all
      EquipmentNeed.where(id: needs.map(&:id)).delete_all
      cleanup_duplicate_review_test_data!(*users)
      Product.where(id: @product&.id).delete_all
    end

    test 'concurrent bids cannot reserve the same remaining unit twice' do
      row = need_row(@first_need)
      race!(
        -> { Bidding.new(actor: actor).create!(number: "#{@prefix}-FIRST", needs: [row]) },
        -> { Bidding.new(actor: actor).create!(number: "#{@prefix}-SECOND", needs: [row]) }
      )
      assert_kind_of Conflict, @contender_error
      assert_equal 1, @first_need.reload.reserved_quantity
      assert_equal 1, @first_need.remaining_quantity
      assert_equal 0, EquipmentItem.where(product: @product).count
      assert_equal 1, BidGroupLine.reserved.where(equipment_need: @first_need).count
    end

    test 'concurrent award of one bid materializes its units and audit once' do
      group = Bidding.new(actor: @admin).create!(number: @prefix, needs: [need_row(@first_need)])
      row_versions = group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }
      race!(-> { award(group.id, row_versions, 'FIRST') }, -> { award(group.id, row_versions, 'SECOND') })
      assert_kind_of Conflict, @contender_error
      assert_equal 0, @first_need.reload.remaining_quantity
      assert_equal 1, EquipmentItem.where(application_id: @first_need.application_id).count
      assert_equal 1, Event.where(action: 'equipment_order_recorded', user: @admin).count
      assert_equal 1, @second_need.reload.remaining_quantity
    end

    test 'award waits for a concurrent catalog edit and refuses the discontinued model' do
      group = Bidding.new(actor: @admin).create!(number: @prefix, needs: [need_row(@first_need)])
      row_versions = group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] }

      race!(-> { Product.find(@product.id).archive! }, -> { award(group.id, row_versions, 'ARCHIVED') })

      assert_kind_of Conflict, @contender_error
      assert_match(/no longer available/, @contender_error.message)
      assert group.reload.open?
      assert_equal 1, @first_need.reload.remaining_quantity
      assert_equal 0, EquipmentItem.where(product: @product).count
      assert_equal 0, Event.where(action: 'equipment_order_recorded', user: @admin).count
    end

    test 'concurrent stock allocation cannot give the last unit to two beneficiaries' do
      stock = StockReceipt.new(actor: @admin).existing!(product: @product, quantity: 1, received_on: Date.current, provenance: 'Verified shelf count').sole
      first_row = need_row(@first_need)
      second_row = need_row(@second_need)
      race!(
        -> { StockAllocation.new(actor: actor).allocate!(needs: [first_row], application_versions: equipment_profile_versions(@first_need.application)) },
        -> { StockAllocation.new(actor: actor).allocate!(needs: [second_row], application_versions: equipment_profile_versions(@second_need.application)) }
      )
      assert_kind_of Conflict, @contender_error
      assert_equal @first_need.application_id, stock.reload.application_id
      assert_equal 0, @first_need.reload.remaining_quantity
      assert_equal 1, @second_need.reload.remaining_quantity
      assert_equal 1, EquipmentItem.reserved_stock.where(product: @product).count
    end

    test 'concurrent receipts reject the stale outstanding set instead of receiving a unit twice' do
      group = Bidding.new(actor: @admin).create!(number: @prefix, purpose: 'program_stock', stock: [{ product_id: @product.id, quantity: 1 }])
      order = Ordering.new(actor: @admin).call(bid_group: group, application_versions: equipment_bid_profile_versions(group), expected_version: group.lock_version,
                                               line_versions: group.active_lines.to_h { |line| [line.id.to_s, line.lock_version.to_s] },
                                               purchase_order_attributes: { number: @prefix, shipping_address_1: '900 Receiving Road',
                                                                            shipping_city: 'Baltimore', shipping_state: 'MD', shipping_zip_code: '21201' })
      Ordering.new(actor: @admin).mark_sent!(order:, sent_at: Date.current, expected_version: order.lock_version)
      version = order.lock_version
      unit_versions = order.equipment_items.to_h { |item| [item.id.to_s, item.lock_version.to_s] }
      action = lambda {
        StockReceipt.new(actor: actor).receive!(order: PurchaseOrder.find(order.id), received_on: Date.current,
                                                rows: [{ batch: order.equipment_items.order(:id).first.stock_receipt_batch, quantity: 1 }], expected_version: version, item_versions: unit_versions)
      }
      race!(action, action)
      assert_kind_of Conflict, @contender_error
      assert_equal 1, order.equipment_items.where.not(stock_received_on: nil).count
      assert_equal 1, Event.where(action: 'equipment_stock_received', user: @admin).count
    end

    test 'two concurrent posts from one existing stock form record one intake' do
      operation_id = SecureRandom.uuid
      attributes = { product: @product, quantity: 2, received_on: Date.current, provenance: 'Counted in storage', operation_id: operation_id }
      action = lambda {
        StockReceipt.new(actor: actor).existing!(**attributes)
      }
      race!(action, action)
      assert_nil @contender_error
      assert_equal 2, EquipmentItem.available_stock.where(product: @product).count
      events = Event.where(user: @admin, action: 'equipment_existing_stock_recorded').with_metadata(:operation_id, operation_id)
      assert_equal 2, events.count
    end

    private

    def actor
      User.find(@admin.id)
    end

    def need_row(need)
      { id: need.id, quantity: 1, lock_version: need.lock_version }
    end

    def award(group_id, row_versions, suffix)
      Ordering.new(actor: actor).call(bid_group: BidGroup.find(group_id), application_versions: equipment_bid_profile_versions(BidGroup.find(group_id)), expected_version: 0,
                                      line_versions: row_versions, purchase_order_attributes: { number: "#{@prefix}-#{suffix}" })
    end

    def race!(first_action, second_action)
      holder_ready = ::Queue.new
      release_holder = ::Queue.new
      holder_pid_queue = ::Queue.new
      contender_pid_queue = ::Queue.new
      @contender_error = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        ApplicationRecord.transaction do
          first_action.call
          holder_ready << true
          wait_for_signal(release_holder)
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        second_action.call
      rescue Conflict, ActiveRecord::RecordInvalid => e
        @contender_error = e
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                 release_queue: release_holder, holder_thread: holder, contender_thread: contender
      )
    ensure
      release_holder << true if release_holder
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end
  end
end
