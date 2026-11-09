# frozen_string_literal: true

require 'test_helper'

class SmsVerificationAttemptConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  setup do
    @service_sid = "VA-race-#{SecureRandom.hex(8)}"
    @phone = "410#{SecureRandom.random_number(8_000_000) + 2_000_000}"
    @digest = AuthRateLimit.contact_digest(@phone)
  end

  teardown do
    SmsVerificationAttempt.where(service_sid: @service_sid, destination_digest: @digest).delete_all
    AuthRateLimitCounter.where(key: "auth_rate_limit:sms_verification:contact:#{@digest}").delete_all
  end

  %i[same different].each do |owner_case|
    test "simultaneous first sends from #{owner_case} owner create one destination lease" do
      ready = Queue.new
      release = Queue.new
      holder_pids = Queue.new
      contender_pids = Queue.new
      first = nil
      second = nil
      holder = on_own_connection do
        holder_pids << backend_pid
        SmsVerificationAttempt.transaction do
          first = reserve('first-browser')
          ready << true
          release.pop
        end
      end
      holder_pid = wait_for_signal(holder_pids, thread: holder)
      wait_for_signal(ready, thread: holder)
      contender = on_own_connection do
        contender_pids << backend_pid
        second = reserve(owner_case == :same ? 'first-browser' : 'other-browser')
      rescue SmsVerificationAttempt::Refused
        second = :refused
      end
      confirm_blocked_then_release(wait_for_signal(contender_pids, thread: contender), holder_pid: holder_pid,
                                                                                       release_queue: release, holder_thread: holder, contender_thread: contender)
      assert first.last.present?
      assert_equal :refused, second
      lease = SmsVerificationAttempt.where(service_sid: @service_sid, destination_digest: @digest, finished_at: nil).sole
      assert_equal first.first.id, lease.id
      assert_equal SmsVerificationAttempt.digest_owner('first-browser'), lease.owner_digest
      assert_equal 'contact_change', lease.purpose
      assert_equal 0, lease.checks_count
    ensure
      release << true if release
      reap_thread(holder, timeout: 10, suppress_errors: true) if holder
      reap_thread(contender, timeout: 10, suppress_errors: true) if contender
    end
  end

  private

  def reserve(owner)
    SmsVerificationAttempt.reserve_send!(service_sid: @service_sid, phone: @phone, purpose: :contact_change, owner: owner)
  end
end
