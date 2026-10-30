# frozen_string_literal: true

require 'test_helper'

module Vouchers
  # The job tests use a fixture transaction; real contention needs committed setup and two connections.
  class ExpirationConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    test 'concurrent sweeps serialize expiration and create one audit and durable notice' do
      ensure_system_audit_actor!
      voucher = create(:voucher, issued_at: 10.years.ago, vendor: nil)
      EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)
      ready = Queue.new
      release = Queue.new
      holder_pid_queue = Queue.new
      first = nil
      second = nil
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        Voucher.find(voucher.id).with_lock do
          first = ExpirationProcessorService.new.call
          ready << true
          release.pop
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(ready, thread: holder)
      contender_pid_queue = Queue.new
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        second = ExpirationProcessorService.new.call
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                 release_queue: release, holder_thread: holder, contender_thread: contender
      )

      assert_predicate first, :success?
      assert_predicate second, :success?
      assert voucher.reload.voucher_expired?
      assert_equal 1, voucher.events.where(action: 'expired').count
      assert_equal 1, Notification.where(notifiable: voucher, action: 'voucher_expired').count
    ensure
      if voucher
        Notification.where(notifiable: voucher).delete_all
        Event.where(auditable: voucher).delete_all
        Voucher.where(id: voucher.id).delete_all
      end
      cleanup_duplicate_review_test_data!(voucher&.application&.user)
    end
  end
end
