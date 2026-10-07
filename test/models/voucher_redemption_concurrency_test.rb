# frozen_string_literal: true

require 'test_helper'

# Two vendors (or two tabs) redeeming the same voucher at once must not both spend its balance.
# Both sides are the real Voucher#redeem! on separate connections.
class VoucherRedemptionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include ConcurrencyTestHelper

  test 'a redemption waits for one in progress and cannot overspend the voucher' do
    Policy.stubs(:voucher_minimum_redemption_amount).returns(10)
    vendor = create(:vendor, :approved)
    voucher = create(:voucher, initial_value: 100, remaining_value: 100, vendor: nil)

    holder_ready = Queue.new
    release_holder = Queue.new
    holder_pid_queue = Queue.new
    holder_thread = on_own_connection do
      holder_pid_queue << backend_pid
      ActiveRecord::Base.transaction do
        Voucher.find(voucher.id).redeem!(60, vendor)
        holder_ready << true
        release_holder.pop
      end
    end
    holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
    wait_for_signal(holder_ready, thread: holder_thread)

    contender_pid_queue = Queue.new
    contender_result = :not_run
    contender_thread = on_own_connection do
      contender_pid_queue << backend_pid
      contender_result = Voucher.find(voucher.id).redeem!(60, vendor)
    end

    confirm_blocked_then_release(
      wait_for_signal(contender_pid_queue, thread: contender_thread),
      holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
    )

    voucher.reload
    assert_equal false, contender_result, 'the second redemption must be refused once the first commits'
    assert_equal 1, voucher.transactions.count
    assert_equal BigDecimal('40.00'), voucher.remaining_value
    assert_operator voucher.transactions.sum(:amount), :<=, voucher.initial_value
  ensure
    if voucher
      VoucherTransaction.where(voucher_id: voucher.id).delete_all
      Event.where(auditable: voucher).delete_all
      Voucher.where(id: voucher.id).delete_all
    end
    cleanup_duplicate_review_test_data!(*[vendor, voucher&.application&.user].compact)
  end
end
