# frozen_string_literal: true

require 'test_helper'

# Integration tests for the WebAuthn second step after password sign-in.
class TwoFactorAuthenticationWebauthnTest < ActionDispatch::IntegrationTest
  include AuthenticationTestHelper

  setup do
    WebAuthn.configure do |config|
      config.allowed_origins = ['https://example.com']
    end

    # Use factories, not the users(:constituent_with_webauthn) fixture, so the
    # credential passes the current model validations.
    @user = create(:constituent, email: 'webauthn_user@example.com')
    @user.update_column(:webauthn_id, WebAuthn.generate_user_id)

    @credential = create(:webauthn_credential, user: @user)
  end

  test 'should get new form for WebAuthn authentication after password step' do
    # Step 1: Sign in, expect redirect to 2FA verify page
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    assert_response :redirect
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn')

    # Step 2: Follow the redirect explicitly
    get verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_response :success

    assert_select 'form'
  end

  test 'should generate options for WebAuthn authentication' do
    # Step 1: Sign in, expect redirect to 2FA verify page
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    assert_response :redirect
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn')

    # Step 2: Follow the redirect explicitly
    get verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_response :success

    # Step 3: Get the options JSON
    get verification_options_two_factor_authentication_path(type: 'webauthn'), xhr: true,
                                                                               headers: { 'X-Requested-With' => 'XMLHttpRequest' }
    assert_response :success

    json_response = response.parsed_body

    assert json_response.present?, 'Response should include JSON data'

    if json_response.is_a?(Hash)
      if json_response.key?('challenge')
        assert json_response['challenge'].present?, 'Challenge should not be empty'
      elsif json_response.key?('publicKey') && json_response['publicKey'].is_a?(Hash)
        assert json_response['publicKey'].key?('challenge'), 'Response should include challenge in publicKey'
      end
    end
  end

  test 'should correctly route WebAuthn credential verification requests' do
    # Step 1: Sign in, expect redirect to 2FA verify page
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    assert_response :redirect
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn')

    # Step 2: Follow the redirect explicitly
    get verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_response :success

    # Step 3: Submit an assertion for a credential the user does not own
    mock_credential = Minitest::Mock.new
    mock_credential.expect :id, 'nonexistent-credential-id'

    WebAuthn::Credential.stub :from_get, mock_credential do
      post process_verification_two_factor_authentication_path(type: 'webauthn'),
           params: { two_factor_authentication: { id: 'test-credential-id' } },
           as: :json

      # Unknown credentials use the same public failure as verifier rejection.
      assert_response :unprocessable_content
    end
  end

  test 'should reject if password step not completed' do
    get verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_redirected_to sign_in_path

    get verification_options_two_factor_authentication_path(type: 'webauthn'), xhr: true
    assert_response :redirect
    assert_redirected_to sign_in_path
  end

  %i[en es].each do |locale|
    test "#{locale} options without password state refuse JSON and redirect browser navigation" do
      options_path = verification_options_two_factor_authentication_path(type: 'webauthn', locale: locale)

      get options_path, headers: { 'Accept' => 'application/json' }

      assert_response :unauthorized
      assert_equal({ 'error' => 'Authentication required' }, response.parsed_body)
      assert_nil response.headers['Location']

      ['text/html', 'text/vnd.turbo-stream.html'].each do |accept|
        get options_path, headers: { 'Accept' => accept }
        assert_redirected_to sign_in_path(locale: locale)
      end

      post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
           params: { two_factor_authentication: { id: @credential.external_id } }, as: :json
      assert_response :unprocessable_content
      assert_equal 'user_session', response.parsed_body['error_code']
      assert_equal I18n.t('two_factor_verification.errors.user_session', locale: locale), response.parsed_body['error']
    end

    test "#{locale} options after pending state was cleared require a fresh password step" do
      post sign_in_path(locale: locale), params: { email: @user.email, password: 'password1234' }
      assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn', locale: locale)
      options_path = verification_options_two_factor_authentication_path(type: 'webauthn', locale: locale)
      get options_path, headers: { 'Accept' => 'application/json' }
      assert_response :success
      assert response.parsed_body['challenge'].present?

      @user.update!(status: :suspended)
      post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
           params: { two_factor_authentication: { id: @credential.external_id } }, as: :json
      assert_response :unprocessable_content
      assert_equal 'user_session', response.parsed_body['error_code']
      @user.update!(status: :active)

      get options_path, headers: { 'Accept' => 'application/json' }

      assert_response :unauthorized
      assert_equal({ 'error' => 'Authentication required' }, response.parsed_body)
      assert_nil response.headers['Location']
      assert_empty @user.sessions
      assert_equal 0, @credential.reload.sign_count
    end
  end

  test 'should have proper error handling for malformed credentials' do
    # Step 1: Sign in, expect redirect to 2FA verify page
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    assert_response :redirect
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn')

    # Step 2: Follow the redirect explicitly
    get verify_method_two_factor_authentication_path(type: 'webauthn')
    assert_response :success

    # Step 3: Submit bad credential data
    mock_credential = Minitest::Mock.new
    mock_credential.expect :id, 'malformed-credential-id'

    WebAuthn::Credential.stub :from_get, mock_credential do
      post process_verification_two_factor_authentication_path(type: 'webauthn'),
           params: { two_factor_authentication: { id: 'malformed-credential-data', type: 'public-key' } },
           as: :json

      # Malformed credentials do not disclose the credential lookup result.
      assert_response :unprocessable_content
    end
  end
end
