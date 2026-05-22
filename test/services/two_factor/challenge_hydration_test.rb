# frozen_string_literal: true

require 'test_helper'

class TwoFactorChallengeHydrationTest < ActiveSupport::TestCase
  setup do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache_store if @original_cache_store
  end

  test 'sms login challenge does not report active when hydrated metadata is not valid for the credential' do
    user = create(:constituent)
    credential = user.sms_credentials.create!(
      phone_number: '555-111-2222',
      last_sent_at: Time.current,
      verified_at: Time.current
    )
    session = { TwoFactorAuth::SESSION_KEYS[:temp_user_id] => user.id }
    challenge = TwoFactor::SmsLoginChallenge.new(session:, credential:)

    Rails.cache.write(
      TwoFactor::SmsLoginChallenge.cache_key(credential.id),
      {
        verification_sid: 'VE_LOGIN_HYDRATE',
        credential_id: credential.id,
        phone_number: '555-999-8888',
        last_sent_at: Time.current.to_i,
        code_expires_at: 10.minutes.from_now.to_i
      },
      expires_in: 10.minutes
    )

    challenge.stubs(:acquire_lock).returns(false)

    assert_equal :sending, challenge.ensure_for!(user)
  end

  test 'pending sms setup challenge does not report active when hydrated metadata is not valid for the phone number' do
    user = create(:constituent)
    session = {}
    challenge = TwoFactor::PendingSmsSetupChallenge.new(
      session:,
      user:,
      phone_number: '555-111-2222'
    )

    Rails.cache.write(
      TwoFactor::PendingSmsSetupChallenge.cache_key(user.id, '555-111-2222'),
      {
        verification_sid: 'VE_SETUP_HYDRATE',
        phone_number: '555-999-8888',
        last_sent_at: Time.current.to_i,
        code_expires_at: 10.minutes.from_now.to_i
      },
      expires_in: 10.minutes
    )

    challenge.stubs(:acquire_lock).returns(false)

    assert_equal :sending, challenge.prepare!
  end
end
