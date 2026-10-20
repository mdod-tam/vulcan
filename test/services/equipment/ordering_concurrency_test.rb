# frozen_string_literal: true

require 'test_helper'

module Equipment
  class OrderingConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @vendor = create(:vendor)
      @first_need = create(:equipment_need)
      @second_need = create(:equipment_need)
    end

    teardown do
      need_ids = [@first_need, @second_need].compact.map(&:id)
      application_ids = EquipmentNeed.where(id: need_ids).pluck(:application_id)
      product_ids = EquipmentNeed.where(id: need_ids).pluck(:product_id)
      users = [@admin, @vendor, *Application.where(id: application_ids).map(&:user)].compact
      orders = PurchaseOrder.where(vendor: @vendor)
      Event.where(user_id: @admin.id).delete_all if @admin
      EquipmentItem.where(application_id: application_ids).delete_all
      EquipmentNeed.where(id: need_ids).delete_all
      orders.delete_all
      cleanup_duplicate_review_test_data!(*users)
      Product.where(id: product_ids).delete_all
    end

    test 'competing consumption of the same remaining unit blocks and cannot materialize it twice' do
      race_orders!(@first_need, @first_need, first_number: 'FIRST-UNIT', second_number: 'SECOND-UNIT')

      assert_kind_of Conflict, @contender_error
      assert_equal 0, @first_need.reload.remaining_quantity
      assert_equal 1, EquipmentItem.where(application: @first_need.application).count
      assert_equal ['FIRST-UNIT'], PurchaseOrder.where(vendor: @vendor).pluck(:number)
      assert_equal 1, Event.where(action: 'equipment_order_recorded', user: @admin).count
      assert_equal 1, @second_need.reload.remaining_quantity
    end

    test 'concurrent duplicate vendor PO creation on separate applications is rejected atomically' do
      race_orders!(@first_need, @second_need, first_number: 'PO 0042', second_number: 'po0042')

      assert_kind_of Conflict, @contender_error
      assert_equal 1, PurchaseOrder.where(vendor: @vendor, normalized_number: 'PO0042').count
      assert_equal 1, EquipmentItem.where(application_id: [@first_need.application_id, @second_need.application_id]).count
      assert_equal 0, @first_need.reload.remaining_quantity
      assert_equal 1, @second_need.reload.remaining_quantity
      assert_equal 1, Event.where(action: 'equipment_order_recorded', user: @admin).count
      assert_equal 1, Event.where(action: 'equipment_need_consumed', user: @admin).count
    end

    private

    def race_orders!(first_need, second_need, first_number:, second_number:)
      holder_ready = ::Queue.new
      release_holder = ::Queue.new
      holder_pid_queue = ::Queue.new
      contender_pid_queue = ::Queue.new
      @contender_error = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        ApplicationRecord.transaction do
          place_order(first_need, first_number)
          holder_ready << true
          wait_for_signal(release_holder)
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        place_order(second_need, second_number)
      rescue Conflict, ActiveRecord::RecordInvalid => e
        @contender_error = e
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender),
        holder_pid: holder_pid,
        release_queue: release_holder, holder_thread: holder, contender_thread: contender
      )
    ensure
      release_holder << true if release_holder
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end

    def place_order(need, number)
      Ordering.new(actor: User.find(@admin.id)).call(
        needs: [{ id: need.id, quantity: 1, lock_version: need.lock_version }], items: [],
        purchase_order_attributes: { vendor_id: @vendor.id, number: number, sent_at: Date.current }
      )
    end
  end
end
