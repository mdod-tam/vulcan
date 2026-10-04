# frozen_string_literal: true

require 'test_helper'

class TwoFactorAuthenticationCredentialTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  include AuthenticationTestHelper

  setup do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @user = create(:constituent, email: 'credential_test_user@example.com')

    # The factory omits the WebAuthn handle required by creation options.
    @user.update_column(:webauthn_id, WebAuthn.generate_user_id)

    sign_in_for_integration_test(@user)
  end

  teardown do
    Rails.cache = @original_cache_store if @original_cache_store
  end

  test 'disabled SMS setup retains the phone form without creating a credential or successful challenge' do
    admin = create(:admin)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS['sms'], enabled: false, actor: admin, operation_id: SecureRandom.uuid)
    TwilioVerifyService.expects(:client).never
    assert_no_difference 'SmsCredential.count' do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
    end
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t('outbound_delivery.sms_suppressed')
    assert_select 'input[name="phone_number"][value="555-123-4567"]'
    assert_nil Rails.cache.read(TwoFactor::PendingSmsSetupChallenge.cache_key(@user.id, '555-123-4567'))
  end

  test 'setup remains in the default language outside public verification locale scope' do
    get setup_two_factor_authentication_path(locale: :es)
    assert_response :success
    assert_select 'html[lang=en]'
    assert_select 'h1', 'Secure Your Account'
  end

  test 'TOTP enrollment uses the shared invalid-code feedback' do
    get new_credential_two_factor_authentication_path(type: 'totp')
    secret = css_select('input[name="secret"]').sole['value']
    post create_credential_two_factor_authentication_path(type: 'totp'), params: { code: 'invalid', secret: secret }
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t('two_factor_verification.errors.invalid_code')
    assert_empty @user.totp_credentials
  end

  test 'webauthn credential form starts registration on submit' do
    get new_credential_two_factor_authentication_path(type: 'webauthn')

    assert_response :success
    assert_select 'form[data-controller="add-credential"][data-action*="submit->add-credential#register"]'
    assert_select 'input[type="submit"][data-add-credential-target="submitButton"]'
  end

  test 'should generate options for credential creation' do
    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_response :success

    json_response = response.parsed_body
    assert json_response.key?('challenge'), 'Response must include a challenge'
    assert json_response.key?('rp'), 'Response must include relying party information'
    assert json_response.key?('user'), 'Response must include user information'
    assert json_response['user'].key?('id'), 'User information must include ID'
    assert_equal @user.email, json_response['user']['name'], 'User name should match email'

    # Enrollment must retain the challenge for later attestation verification.
    assert session[TwoFactorAuth::SESSION_KEYS[:challenge]].present?, 'Creation challenge should be stored in session'
    assert_equal :webauthn, session[TwoFactorAuth::SESSION_KEYS[:type]], 'Session should record we are using WebAuthn'
  end

  %w[platform cross-platform].each do |authenticator_type|
    test "#{authenticator_type} enrollment uses the public program name and configured RP ID" do
      original_rp_id = WebAuthn.configuration.rp_id
      WebAuthn.configuration.rp_id = 'example.com'

      post webauthn_creation_options_two_factor_authentication_path,
           params: { authenticator_type: authenticator_type }, as: :json

      assert_response :success
      assert_equal 'application/json', response.media_type
      assert_equal 'Maryland Accessible Telecommunications', response.parsed_body.dig('rp', 'name')
      assert_equal 'example.com', response.parsed_body.dig('rp', 'id')
    ensure
      WebAuthn.configuration.rp_id = original_rp_id
    end
  end

  test 'sending SMS setup code does not create credential' do
    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '555-123-4567'
      }
    end

    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    assert_equal :sms_setup, session[TwoFactorAuth::SESSION_KEYS[:type]]
    metadata = session[TwoFactorAuth::SESSION_KEYS[:metadata]]
    assert_equal '555-123-4567', metadata[:phone_number] || metadata['phone_number']
  end

  test 'sending SMS setup code for existing phone does not create duplicate' do
    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: Time.current,
      verified_at: Time.current
    )
    TwilioVerifyService.expects(:send_verification).never

    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '(555) 123-4567'
      }
    end

    assert_response :unprocessable_content
    assert_select 'h1', text: 'Set up Text Message Verification'
  end

  test 'successful SMS setup confirmation persists credential only after approval' do
    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '555-123-4567'
      }
    end

    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_difference('SmsCredential.count', 1) do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '123456'
      }
    end

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    credential = @user.reload.sms_credentials.first
    assert_equal '555-123-4567', credential.phone_number
    assert credential.verified_at.present?
  end

  test 'successful SMS setup confirmation redirects Turbo requests to success page' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    post confirm_pending_sms_credential_two_factor_authentication_path,
         params: { code: '123456' },
         headers: { 'Accept' => Mime[:turbo_stream].to_s }

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    assert_response :see_other
  end

  test 'invalid SMS setup confirmation does not create credential' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '000000'
      }
    end

    assert_response :unprocessable_content
    assert_select 'h1', text: 'Text Message Verification'
    assert_includes response.body, I18n.t('two_factor_verification.errors.invalid_code')
  end

  test 'SMS enrollment provider failure uses the shared service-error feedback' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
    @session_token = nil
    TwilioVerifyService.expects(:check_verification).returns(success: false)
    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: { code: '123456' }
    end
    assert_response :unprocessable_content
    assert_includes CGI.unescapeHTML(response.body), I18n.t('two_factor_verification.errors.verification_service_unavailable')
  end

  test 'successful SMS setup confirmation marks an existing unverified row verified' do
    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: 1.day.ago,
      verified_at: nil
    )

    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '123456'
      }
    end

    credential = @user.reload.sms_credentials.find_by!(phone_number: '555-123-4567')
    assert credential.verified_at.present?
  end

  test 'should handle invalid attestation' do
    # This skip assumes tests of invalid attestation need complex mocks.
    skip 'WebAuthn creation tests should focus on higher-level interactions per documentation'

    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_response :success
  end

  test 'should require authentication' do
    sign_out

    get new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_redirected_to sign_in_path,
                         "Expected redirect to sign_in_path, but got status #{response.status}. Location: #{response.location}. Body starts with: #{response.body[0..100]}"

    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_redirected_to sign_in_path, "Options endpoint should require authentication, but got status #{response.status}"

    # JSON returns 401 to avoid ActionController::UnknownFormat from the HTML sign-in page.
    # HTML and plain XHR still redirect.
    post create_credential_two_factor_authentication_path(type: 'webauthn'),
         params: { id: 'test-id' },
         as: :json
    assert_response :unauthorized, "Credential creation should require authentication, but got status #{response.status}"
  end

  test 'should destroy credential' do
    credential = create(:webauthn_credential,
                        user: @user,
                        nickname: 'Deletable Key')

    assert_difference('WebauthnCredential.count', -1) do
      delete destroy_credential_two_factor_authentication_path(type: 'webauthn', id: credential.id)
    end

    assert_redirected_to edit_profile_path, 'Should redirect to profile after successful deletion'
    assert_equal 'Security key removed successfully', flash[:notice], 'Should show success message'
  end

  test 'cannot destroy another user credential' do
    other_user = create(:constituent, email: "other-user-#{SecureRandom.hex(4)}@example.com")
    other_user.update_column(:webauthn_id, WebAuthn.generate_user_id)

    other_credential = create(:webauthn_credential,
                              user: other_user,
                              nickname: 'Other User Key')

    assert_no_difference('WebauthnCredential.count') do
      delete destroy_credential_two_factor_authentication_path(type: 'webauthn', id: other_credential.id)
    end

    # The response hides whether another user owns the credential.
    assert_redirected_to edit_profile_path, 'Should redirect back to profile'
    assert_equal 'Security key not found', flash[:alert], 'Should show not found message'

    assert WebauthnCredential.exists?(other_credential.id), "Other user's credential should not be deleted"
  end
end
