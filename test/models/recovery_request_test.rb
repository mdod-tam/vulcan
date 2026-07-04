# frozen_string_literal: true

require 'test_helper'

class RecoveryRequestTest < ActiveSupport::TestCase
  setup do
    # Use a sequence for the email to avoid collisions
    @user = FactoryBot.create(:user, email: "recovery-user-#{SecureRandom.hex(4)}@example.com")
    @admin = FactoryBot.create(:admin, email: "recovery-admin-#{SecureRandom.hex(4)}@example.com")
  end

  test 'should create valid recovery request' do
    request = RecoveryRequest.new(
      user: @user,
      status: 'pending',
      details: 'Lost my security key',
      ip_address: '127.0.0.1',
      user_agent: 'Test Agent'
    )

    assert request.valid?
    assert request.save
  end

  test 'should require user association' do
    request = RecoveryRequest.new(
      status: 'pending',
      details: 'Lost my security key'
    )

    assert_not request.valid?
    assert_includes request.errors.full_messages, 'User must exist'
  end

  test 'should have pending status by default' do
    request = RecoveryRequest.new(user: @user)
    assert_equal 'pending', request.status
  end

  test 'database enforces one pending recovery request per user' do
    FactoryBot.create(:recovery_request, user: @user, status: 'pending')

    assert_raises(ActiveRecord::RecordNotUnique) do
      FactoryBot.create(:recovery_request, user: @user, status: 'pending')
    end
  end

  test 'database allows a new pending recovery request after prior request is resolved' do
    FactoryBot.create(:recovery_request, :approved, user: @user)

    request = FactoryBot.build(:recovery_request, user: @user, status: 'pending')

    assert request.save
  end

  test 'should approve request and clear user credentials' do
    # Set up WebAuthn credential for the user
    create_webauthn_credential_for(@user)

    # Create recovery request
    request = FactoryBot.create(:recovery_request, user: @user)

    # Process the recovery request
    request.update!(
      status: 'approved',
      resolved_at: Time.current,
      resolved_by_id: @admin.id
    )

    # Delete credentials as part of approval (simulating what controller would do)
    @user.webauthn_credentials.destroy_all

    # Assertions
    assert_equal 'approved', request.status
    assert_not_nil request.resolved_at
    assert_equal @admin.id, request.resolved_by_id
    assert_equal 0, @user.webauthn_credentials.count
  end

  private

  def create_webauthn_credential_for(user)
    WebAuthn.configure do |config|
      config.allowed_origins = ['https://example.com']
    end
    fake_client = WebAuthn::FakeClient.new('https://example.com')

    credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })
    credential_hash = fake_client.create(challenge: credential_options.challenge)

    user.webauthn_credentials.create!(
      external_id: credential_hash['id'],
      public_key: 'dummy_public_key_for_testing',
      nickname: 'Test Key',
      sign_count: 0
    )
  end
end
