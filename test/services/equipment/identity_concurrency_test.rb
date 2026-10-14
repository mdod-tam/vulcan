# frozen_string_literal: true

require 'test_helper'

module Equipment
  class IdentityConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @admin = create(:admin)
      @first = create(:equipment_item)
      other_model = create(:product, manufacturer: " #{@first.product.manufacturer.upcase} ", model_number: 'Different model')
      @second = create(:equipment_item, product: other_model)
    end

    teardown do
      items = [@first, @second].compact
      orders = items.filter_map(&:purchase_order)
      users = [@admin, *items.map { |item| item.application.user }, *orders.map(&:vendor)].compact
      Event.where(auditable: items).delete_all
      EquipmentItem.where(id: items.map(&:id)).delete_all
      PurchaseOrder.where(id: orders.map(&:id)).delete_all
      cleanup_duplicate_review_test_data!(*users)
      Product.where(id: items.map(&:product_id)).delete_all
    end

    test 'competing IMEI assignments on different applications cannot both become active' do
      race_corrections!({ imei: '123456789012345' }, { imei: '123456789012345' })

      assert_kind_of Conflict, @contender_error
      assert_equal 1, EquipmentItem.active.where(normalized_imei: '123456789012345').count
      assert_nil @second.reload.imei
      assert_equal 1, Event.where(action: 'equipment_item_corrected', user: @admin).count
    end

    test 'competing cross-model serial assignments require acknowledgment after the first commits' do
      race_corrections!({ serial_number: 'MODEL-SERIAL' }, { serial_number: ' model-serial ' })

      assert_kind_of ActiveRecord::RecordInvalid, @contender_error
      assert_includes @contender_error.record.errors[:serial_number].join, 'provide an acknowledgment reason'
      assert_equal [@first.id], @contender_error.record.identity_conflicts.map(&:id)
      assert_nil @second.reload.serial_number
      assert_equal 0, @second.lock_version
      assert_equal 1, Event.where(action: 'equipment_item_corrected', user: @admin).count

      acknowledgment = 'Manufacturer confirmed this serial is reused across these models.'
      Correction.new(actor: @admin).update_item!(item: @second, attributes: { serial_number: ' model-serial ' }, expected_version: 0,
                                                 reason: 'Serial reviewed', serial_duplicate_reason: acknowledgment)
      assert_equal 2, EquipmentItem.active.where(normalized_manufacturer: @first.normalized_manufacturer,
                                                 normalized_serial_number: 'MODEL-SERIAL').count
      assert_equal acknowledgment, @second.events.last.metadata['serial_duplicate_reason']
      assert_equal 2, Event.where(action: 'equipment_item_corrected', user: @admin).count
    end

    test 'direct saves also serialize the cross-model serial acknowledgment check' do
      attributes = { serial_number: 'MODEL-SERIAL' }
      race_corrections!(attributes, attributes) { |item| item.update!(attributes) }

      assert_kind_of ActiveRecord::RecordInvalid, @contender_error
      assert_nil @second.reload.serial_number
      assert_equal 1, Event.where(action: 'equipment_item_corrected', user: @admin).count
    end

    private

    def race_corrections!(first_attributes, second_attributes)
      holder_ready = ::Queue.new
      release_holder = ::Queue.new
      holder_pid_queue = ::Queue.new
      @contender_error = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        EquipmentItem.transaction do
          Correction.new(actor: @admin).update_item!(item: EquipmentItem.find(@first.id), attributes: first_attributes, expected_version: 0, reason: 'First assignment')
          holder_ready << true
          wait_for_signal(release_holder)
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender_pid_queue = ::Queue.new
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        item = EquipmentItem.find(@second.id)
        if block_given?
          yield item
        else
          Correction.new(actor: @admin).update_item!(item: item, attributes: second_attributes, expected_version: 0, reason: 'Competing assignment')
        end
      rescue Conflict, ActiveRecord::RecordInvalid => e
        @contender_error = e
      end
      confirm_blocked_then_release(wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                                            release_queue: release_holder, holder_thread: holder, contender_thread: contender)
    ensure
      release_holder << true if release_holder
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end
  end
end
