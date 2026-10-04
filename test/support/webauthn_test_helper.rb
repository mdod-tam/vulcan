# frozen_string_literal: true

require 'webauthn/fake_client'

module WebauthnTestHelper
  def setup_two_factor_session(user, type = :webauthn)
    post sign_in_path, params: {
      email: user.email,
      password: 'password123'
    }

    session[:pending_user_id] = user.id
    session[TwoFactorAuth::SESSION_KEYS[:type]] = type
    session[:two_factor_auth_in_progress] = user.id

    true
  end

  def create_fake_credential(user, client, options = {})
    # Without HTTP request methods, create the record directly.
    return create_webauthn_credential_directly(user, client, options) unless respond_to?(:get)

    get webauthn_creation_options_two_factor_authentication_path, xhr: true
    challenge = session[TwoFactorAuth::SESSION_KEYS[:challenge]]

    attestation_response = client.create(
      challenge: challenge,
      rp_id: URI.parse(client.origin).host,
      user_present: options[:user_present] || true,
      user_verified: options[:user_verified] || true
    )

    mock_credential = Minitest::Mock.new
    mock_credential.expect :id, attestation_response['id']
    mock_credential.expect :public_key, 'dummy_public_key_for_testing'
    mock_credential.expect :sign_count, 0

    # The stub skips attestation verification.
    WebAuthn::Credential.stub :from_create, mock_credential do
      mock_credential.expect :verify, true, [String]

      return nil unless respond_to?(:post)

      post create_credential_two_factor_authentication_path(type: 'webauthn'), params: {
        id: attestation_response['id'],
        response: {
          attestationObject: attestation_response['response']['attestationObject'],
          clientDataJSON: attestation_response['response']['clientDataJSON']
        },
        credential_nickname: options[:nickname] || 'Test Security Key'
      }, as: :json
    end

    WebauthnCredential.find_by(nickname: options[:nickname] || 'Test Security Key')
  end

  # The record has a dummy public key, so it cannot verify a real assertion.
  def create_webauthn_credential_directly(user, client, options = {})
    # The return value is not used.
    client.create(
      # WebAuthn challenges are base64-url strings without padding
      challenge: Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false),
      rp_id: URI.parse(client.origin).host,
      user_present: options[:user_present] || true,
      user_verified: options[:user_verified] || true
    )

    user.webauthn_credentials.create!(
      # WebAuthn uses URL-safe Base64 with no padding.
      external_id: Base64.urlsafe_encode64(SecureRandom.random_bytes(16), padding: false),
      public_key: 'dummy_public_key_for_testing',
      nickname: options[:nickname] || 'Test Security Key',
      sign_count: 0
    )
  end

  def mock_webauthn_assertion(client, options = {})
    challenge = options[:challenge] || SecureRandom.random_bytes(32)

    session[TwoFactorAuth::SESSION_KEYS[:challenge]] = challenge
    session[TwoFactorAuth::SESSION_KEYS[:type]] = :webauthn

    client.get(
      challenge: challenge,
      rp_id: URI.parse(client.origin).host,
      user_present: options[:user_present] || true,
      user_verified: options[:user_verified] || true,
      sign_count: options[:sign_count] || 1
    )
  end

  def setup_webauthn_test_environment
    WebAuthn.configure do |config|
      config.allowed_origins = ['https://example.com']
    end

    @fake_client = WebAuthn::FakeClient.new('https://example.com')
  end

  def fake_client
    @fake_client ||= setup_webauthn_test_environment
  end

  # Alias for older system tests.
  def create_webauthn_credential_programmatically(user, client, nickname = 'Test Security Key')
    create_fake_credential(user, client, nickname: nickname)
  end

  # Does not read the session. Returns a new challenge that the server does not know.
  def retrieve_session_webauthn_challenge(options = {})
    if options[:fetch_options] && options[:user]
      user = options[:user]
      return nil unless user&.webauthn_credentials&.any?

      get_options = WebAuthn::Credential.options_for_get(
        allow: user.webauthn_credentials.pluck(:external_id)
      )

      get_options.challenge
    else
      create_options = WebAuthn::Credential.options_for_create(
        user: { id: SecureRandom.uuid, name: 'test@example.com' }
      )

      create_options.challenge
    end
  end
end
