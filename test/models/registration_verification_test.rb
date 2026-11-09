# frozen_string_literal: true

require 'test_helper'

class RegistrationVerificationTest < ActiveSupport::TestCase
  test 'only real email destinations can become verification records' do
    [nil, '', 'invalid', 'dependent@system.matvulcan.local', ' DEPENDENT@SYSTEM.MATVULCAN.LOCAL '].each do |email|
      proof = RegistrationVerification.new(email: email, locale: 'en', expires_at: 20.minutes.from_now)

      assert_no_difference('RegistrationVerification.count') { assert_not proof.save }
      assert proof.errors.of_kind?(:email, :invalid)
    end
  end

  test 'issued email and deadline cannot be replaced to reuse a signed row' do
    proof = RegistrationVerification.create!(email: ' PROOF@EXAMPLE.TEST ', locale: 'en', expires_at: 20.minutes.from_now)
    token = proof.proof_token
    assert_equal 'proof@example.test', proof.email
    assert_not proof.update(email: 'replacement@example.test', expires_at: 1.hour.from_now)
    assert_equal proof, RegistrationVerification.resolve(token)

    proof.reload.update!(consumed_at: Time.current)
    assert_nil RegistrationVerification.resolve(token)
    assert_not proof.update(consumed_at: nil)
    assert_nil RegistrationVerification.resolve(token)
  end

  test 'cleanup deletes expired payloads without removing created accounts or current proofs' do
    user = create(:constituent)
    expired = RegistrationVerification.create!(email: user.email, locale: 'en', expires_at: 2.days.ago,
                                               consumed_at: 2.days.ago, created_user: user)
    current = RegistrationVerification.create!(email: 'current@example.test', locale: 'en', expires_at: 20.minutes.from_now)
    PruneRegistrationVerificationsJob.perform_now

    assert_not RegistrationVerification.exists?(expired.id)
    assert RegistrationVerification.exists?(current.id)
    assert User.exists?(user.id)
  end
end
