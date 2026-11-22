# frozen_string_literal: true

require 'test_helper'

module Equipment
  class BatchConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      FeatureFlag.disable!(:vouchers_enabled)
      @admin = create(:admin)
      @products = create_list(:product, 2)
      @needs = []
    end

    teardown do
      units = EquipmentItem.where(product_id: @products.map(&:id))
      Event.where(user_id: @admin.id).delete_all
      units.delete_all
      EquipmentNeed.where(id: @needs.map(&:id)).delete_all
      cleanup_duplicate_review_test_data!(@admin, *@needs.map { |need| need.application.user })
      Product.where(id: @products.map(&:id)).delete_all
    end

    test 'inverse multi-model allocations do not deadlock or partially reserve stock' do
      first = needs_for(@products)
      second = needs_for(@products.reverse)
      @products.each do |product|
        StockReceipt.new(actor: @admin).existing!(product: product, quantity: 2, received_on: Date.current, provenance: 'Verified shelf count')
      end
      actions = [first, second].map do |needs|
        lambda do
          StockAllocation.new(actor: actor).allocate!(needs: needs.map { |need| { id: need.id, quantity: 1, lock_version: need.lock_version } },
                                                      application_versions: equipment_profile_versions(needs.first.application))
        end
      end

      race_after_sql!(*actions) { |payload| payload[:sql].start_with?('UPDATE "equipment_items"') }

      assert_nil @holder_error, @holder_error&.full_message
      assert_kind_of Conflict, @contender_error
      assert_equal 2, EquipmentItem.reserved_stock.where(application_id: first.first.application_id).count
      assert_empty EquipmentItem.where(application_id: second.first.application_id)
      assert_equal([0, 0], first.map { |need| need.reload.remaining_quantity })
      assert_equal([1, 1], second.map { |need| need.reload.remaining_quantity })
      assert_equal 2, EquipmentItem.available_stock.where(product_id: @products.map(&:id)).count
      assert_equal 2, Event.where(action: 'equipment_stock_allocated', user: @admin).count
    end

    test 'inverse serial batches serialize before saving and roll back the losing receipt' do
      actions = [%w[BATCH-A BATCH-B], %w[BATCH-B BATCH-A]].map do |serials|
        lambda do
          StockReceipt.new(actor: actor).existing!(product: @products.first, quantity: 2, received_on: Date.current,
                                                   provenance: 'Verified serial batch', identifiers: serials.map { |serial| { serial_number: serial } })
        end
      end

      race_after_sql!(*actions) { |payload| payload[:name] == 'Equipment identity assignment lock' }

      assert_nil @holder_error, @holder_error&.full_message
      assert_kind_of ActiveRecord::RecordInvalid, @contender_error
      assert_equal %w[BATCH-A BATCH-B], EquipmentItem.where(product: @products.first).order(:normalized_serial_number).map(&:serial_number).sort
      assert_equal 2, Event.where(action: 'equipment_existing_stock_recorded', user: @admin).count
    end

    test 'inverse IMEI batches do not deadlock on the unique identifier index' do
      actions = [%w[123456789012345 123456789012346], %w[123456789012346 123456789012345]].map do |imeis|
        lambda do
          StockReceipt.new(actor: actor).existing!(product: @products.first, quantity: 2, received_on: Date.current,
                                                   provenance: 'Verified IMEI batch', identifiers: imeis.map { |imei| { imei: imei } })
        end
      end

      race_after_sql!(*actions) { |payload| payload[:sql].start_with?('INSERT INTO "equipment_items"') }

      assert_nil @holder_error, @holder_error&.full_message
      assert_kind_of ActiveRecord::RecordInvalid, @contender_error
      assert_equal 2, EquipmentItem.where(product: @products.first).count
      assert_equal 2, Event.where(action: 'equipment_existing_stock_recorded', user: @admin).count
    end

    private

    def actor
      User.find(@admin.id)
    end

    def needs_for(products)
      first = create(:equipment_need, product: products.first)
      second = create(:equipment_need, application: first.application, product: products.last)
      @needs.push(first, second)
      [first, second]
    end

    def race_after_sql!(first_action, second_action, &pause_on)
      ready = ::Queue.new
      release = ::Queue.new
      contender_pid = ::Queue.new
      @holder_error = @contender_error = nil
      holder = on_own_connection do
        owner = Thread.current
        paused = false
        observer = lambda do |_name, _start, _finish, _id, payload|
          next unless Thread.current == owner && !paused && pause_on.call(payload)

          paused = true
          ready << backend_pid
          wait_for_signal(release)
        end
        ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') { first_action.call }
      rescue StandardError => e
        @holder_error = e
        raise unless paused
      end
      holder_pid = wait_for_signal(ready, thread: holder)
      contender = on_own_connection do
        contender_pid << backend_pid
        second_action.call
      rescue StandardError => e
        @contender_error = e
      end
      confirm_blocked_then_release(wait_for_signal(contender_pid, thread: contender), holder_pid: holder_pid,
                                                                                      release_queue: release, holder_thread: holder, contender_thread: contender)
    ensure
      release << true if release
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end
  end
end
