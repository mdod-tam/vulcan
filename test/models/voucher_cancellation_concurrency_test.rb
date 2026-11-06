# frozen_string_literal: true

require 'test_helper'

# A cancellation that loses a race to a redemption or an expiry must leave that result in place.
# Real contention needs committed setup and two connections.
class VoucherCancellationConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  test 'cancellation waits for an in-flight redemption and leaves the redeemed voucher redeemed' do
    admin = create(:admin)
    vendor = create(:vendor)
    voucher = create(:voucher, :active, vendor: nil, initial_value: 100)

    cancelled = cancel_while_holding(voucher, admin) { Voucher.find(voucher.id).redeem!(100, vendor) }

    assert_not cancelled
    assert_predicate voucher.reload, :voucher_redeemed?
    assert_equal 1, voucher.transactions.count
  ensure
    if voucher
      VoucherTransaction.where(voucher_id: voucher.id).delete_all
      Event.where(auditable: voucher).delete_all
      Voucher.where(id: voucher.id).delete_all
    end
    cleanup_duplicate_review_test_data!(voucher&.application&.user, vendor, admin)
  end

  test 'cancellation waits for an in-flight expiry and leaves the expired voucher expired' do
    system_actor_existed = PublicAuditActor.system_audit_actor.present?
    system_actor = ensure_system_audit_actor!
    admin = create(:admin)
    voucher = create(:voucher, :active, vendor: nil, issued_at: 10.years.ago)
    EmailDelivery::NotificationDispatch.any_instance.stubs(:call).returns(true)

    cancelled = cancel_while_holding(voucher, admin) { assert_predicate Vouchers::ExpirationProcessorService.new.call, :success? }

    assert_not cancelled
    assert_predicate voucher.reload, :voucher_expired?
    assert_equal 1, voucher.events.where(action: 'expired').count
  ensure
    if voucher
      Notification.where(notifiable: voucher).delete_all
      Event.where(auditable: voucher).delete_all
      Voucher.where(id: voucher.id).delete_all
    end
    cleanup_duplicate_review_test_data!(voucher&.application&.user, admin, (system_actor unless system_actor_existed))
  end

  private

  # Runs the block in an open transaction on its own connection, starts a cancellation that must block on the
  # voucher row, then commits the block's work. Returns what cancel! returned once it could proceed.
  def cancel_while_holding(voucher, actor, &hold)
    ready = Queue.new
    release = Queue.new
    holder_pid_queue = Queue.new
    contender_pid_queue = Queue.new
    cancelled = nil
    holder = on_own_connection do
      holder_pid_queue << backend_pid
      Voucher.transaction do
        hold.call
        ready << true
        release.pop
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
    wait_for_signal(ready, thread: holder)
    contender = on_own_connection do
      contender_pid_queue << backend_pid
      cancelled = Voucher.find(voucher.id).cancel!(actor: actor)
    end
    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                               release_queue: release, holder_thread: holder, contender_thread: contender
    )
    cancelled
  end
end
