# frozen_string_literal: true

require 'test_helper'

class SmsVerificationAttemptTest < ActiveSupport::TestCase
  setup do
    @service_sid = "VA-test-#{SecureRandom.hex(8)}"
    @phone = "410#{SecureRandom.random_number(8_000_000) + 2_000_000}"
    @owner = 'contact-change:fixture-session:1'
  end

  test 'cooldown reuses the bound receipt and resend never extends its original deadline' do
    freeze_time do
      attempt = sent_attempt
      deadline = attempt.expires_at
      ownership_deadline = attempt.ownership_expires_at
      travel SmsVerificationAttempt::COOLDOWN - 1.second
      same, version = reserve_send
      assert_equal attempt.id, same.id
      assert_nil version
      assert_equal 'VE-first', same.verification_sid
      assert_equal deadline, same.expires_at
      assert_equal ownership_deadline, same.ownership_expires_at

      travel 2.seconds
      same, version = reserve_send
      assert_equal attempt.id, same.id
      assert version.present?
      same.finish_send!(version: version, sid: 'VE-resend', provider_created_at: Time.current)
      assert_equal deadline, same.reload.expires_at
      assert_equal ownership_deadline, same.ownership_expires_at
      assert_equal 'VE-resend', same.verification_sid
    end
  end

  test 'wrong purpose owner and SID cannot check or take over a live destination' do
    attempt = sent_attempt
    original_deadline = attempt.expires_at
    assert_raises(SmsVerificationAttempt::Refused) { reserve_send(purpose: :reauthentication) }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_send(owner: 'different-browser') }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_check(purpose: :login) }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_check(owner: 'different-browser') }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_check(verification_sid: 'VE-wrong') }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_check(verification_sid: nil) }
    assert_equal 0, attempt.reload.checks_count
    assert_nil attempt.approved_at
    assert_nil attempt.finished_at
    assert_equal original_deadline, attempt.expires_at
    assert_not_includes attempt.phone_number_before_type_cast, PhoneNumber.normalize(@phone)
  end

  test 'local exhaustion retains ownership until the fixed provider lifetime ends' do
    freeze_time do
      attempt = sent_attempt
      deadline = attempt.expires_at
      ownership_deadline = attempt.ownership_expires_at
      SmsVerificationAttempt::MAX_CHECKS.times do
        checked, version = reserve_check
        checked.finish_check!(version: version, approved: false, terminal: false)
      end
      assert_equal SmsVerificationAttempt::MAX_CHECKS, attempt.reload.checks_count
      assert_nil attempt.finished_at
      assert_raises(SmsVerificationAttempt::Refused) { reserve_check }
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send }
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send(owner: 'next-browser') }

      travel_to deadline + 1.second
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send(owner: 'next-browser') }
      assert_equal ownership_deadline, attempt.reload.ownership_expires_at
      assert_nil attempt.finished_at

      travel_to ownership_deadline + 1.second
      replacement, version = reserve_send(owner: 'next-browser')
      assert version.present?
      assert_not_equal attempt.id, replacement.id
      assert attempt.reload.finished_at
      assert_equal SmsVerificationAttempt.digest_owner('next-browser'), replacement.owner_digest
    end
  end

  test 'delayed provider issuance retains destination ownership beyond local code expiry' do
    freeze_time do
      attempt, version = reserve_send
      entry_deadline = attempt.expires_at
      ownership_deadline = attempt.ownership_expires_at
      travel 5.seconds
      provider_created_at = Time.current
      attempt.finish_send!(version: version, sid: 'VE-first', provider_created_at: provider_created_at)
      assert_equal entry_deadline, attempt.reload.expires_at
      assert_equal ownership_deadline, attempt.ownership_expires_at
      assert_operator attempt.ownership_expires_at, :>=, provider_created_at + SmsVerificationAttempt::TTL

      travel_to entry_deadline + 1.second
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send(purpose: :reauthentication, owner: 'another-operation') }
      assert_raises(SmsVerificationAttempt::Refused) { reserve_check }
      assert_nil attempt.reload.finished_at

      travel_to ownership_deadline + 1.second
      replacement, next_version = reserve_send(purpose: :reauthentication, owner: 'another-operation')
      assert next_version.present?
      assert_not_equal attempt.id, replacement.id
      assert attempt.reload.finished_at
    end
  end

  test 'terminal provider refusal does not free an unexpired destination for another purpose' do
    attempt = sent_attempt
    checked, version = reserve_check
    checked.finish_check!(version: version, approved: false, terminal: true)
    assert_equal SmsVerificationAttempt::MAX_CHECKS, attempt.reload.checks_count
    assert_nil attempt.finished_at
    assert_raises(SmsVerificationAttempt::Refused) { reserve_send(purpose: :reauthentication, owner: 'another-operation') }
    assert_raises(SmsVerificationAttempt::Refused) { reserve_send }
  end

  test 'a consumed approval permits a new owner and its old receipt cannot authenticate again' do
    attempt = sent_attempt
    checked, version = reserve_check
    checked.finish_check!(version: version, approved: true, terminal: false)
    assert attempt.reload.approved_at
    assert attempt.finished_at
    replacement, send_version = reserve_send(purpose: :reauthentication, owner: 'new-operation')
    assert send_version.present?
    assert_not_equal attempt.id, replacement.id
    assert_raises(SmsVerificationAttempt::Refused) { reserve_check }
    assert_raises(SmsVerificationAttempt::Refused) do
      attempt.finish_check!(version: version, approved: true, terminal: false)
    end
  end

  test 'an older provider creation time shortens the deadline without granting a new lifetime' do
    freeze_time do
      attempt, version = reserve_send
      ownership_deadline = attempt.ownership_expires_at
      attempt.finish_send!(version: version, sid: 'VE-first', provider_created_at: 2.minutes.ago)
      assert_equal 8.minutes.from_now, attempt.reload.expires_at
      assert_equal ownership_deadline, attempt.ownership_expires_at
      travel SmsVerificationAttempt::COOLDOWN + 1.second
      same, next_version = reserve_send
      same.finish_send!(version: next_version, sid: 'VE-resend', provider_created_at: Time.current)
      assert_equal attempt.expires_at, same.reload.expires_at
      assert_equal ownership_deadline, same.ownership_expires_at
    end
  end

  test 'a delayed send receipt cannot replace the receipt of a later reserved call' do
    freeze_time do
      attempt, first_version = reserve_send
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send }
      travel SmsVerificationAttempt::CALL_TIMEOUT + 1.second
      later, later_version = reserve_send
      assert_not_equal first_version, later_version
      assert_raises(SmsVerificationAttempt::Refused) { attempt.finish_send!(version: first_version, sid: 'VE-stale') }
      later.finish_send!(version: later_version, sid: 'VE-current')
      assert_equal 'VE-current', attempt.reload.verification_sid
    end
  end

  test 'send and check calls cannot overlap for the same live provider challenge' do
    freeze_time do
      sent_attempt
      travel SmsVerificationAttempt::COOLDOWN + 1.second
      sending, send_version = reserve_send
      assert_raises(SmsVerificationAttempt::Refused) { reserve_check }
      sending.finish_send!(version: send_version, sid: 'VE-current')
      checking, check_version = reserve_check(verification_sid: 'VE-current')
      assert_raises(SmsVerificationAttempt::Refused) { reserve_send }
      checking.finish_check!(version: check_version, approved: false, terminal: false)
      same, next_send = reserve_send
      assert_equal checking.id, same.id
      assert_nil next_send, 'Within cooldown the existing receipt is reused after the check completes'
    end
  end

  private

  def reserve_send(purpose: :contact_change, owner: @owner)
    SmsVerificationAttempt.reserve_send!(service_sid: @service_sid, phone: @phone, purpose: purpose, owner: owner)
  end

  def reserve_check(purpose: :contact_change, owner: @owner, verification_sid: 'VE-first')
    SmsVerificationAttempt.reserve_check!(service_sid: @service_sid, phone: @phone, purpose: purpose,
                                          owner: owner, verification_sid: verification_sid)
  end

  def sent_attempt
    attempt, version = reserve_send
    attempt.finish_send!(version: version, sid: 'VE-first', provider_created_at: Time.current)
    attempt.reload
  end
end
