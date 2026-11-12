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

    Current.reset
    post sign_in_path, params: { contact: @user.email, password: 'password1234' }
    assert_redirected_to constituent_portal_dashboard_path
  end

  teardown do
    Rails.cache = @original_cache_store if @original_cache_store
  end

  test 'disabled SMS setup retains the phone form without creating a credential or successful challenge' do
    ensure_system_audit_actor!
    admin = create(:admin)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::CHANNEL_CONTROLS['sms'], enabled: false, actor: admin, operation_id: SecureRandom.uuid)
    TwilioVerifyService.expects(:client).never
    assert_no_difference 'SmsCredential.count' do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
    end
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t('outbound_delivery.sms_suppressed')
    assert_select 'input[name="phone_number"][value="555-123-4567"]'
    assert_empty SmsVerificationAttempt.where(purpose: 'setup')
  end

  test 'setup remains in the default language outside public verification locale scope' do
    get setup_two_factor_authentication_path(locale: :es)
    assert_response :success
    assert_select 'html[lang=en]'
    assert_select 'h1', 'Secure Your Account'
  end

  test 'TOTP enrollment uses the shared invalid-code feedback' do
    get new_credential_two_factor_authentication_path(type: 'totp')
    secret = session[TwoFactorAuth::SESSION_KEYS[:metadata]].with_indifferent_access.fetch(:secret)
    post create_credential_two_factor_authentication_path(type: 'totp'), params: { code: 'invalid', secret: secret }
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t('two_factor_verification.errors.invalid_code')
    assert_empty @user.totp_credentials
  end

  test 'TOTP enrollment over Turbo answers an invalid code with only a flash stream, then accepts the corrected code' do
    get new_credential_two_factor_authentication_path(type: 'totp')
    secret = session[TwoFactorAuth::SESSION_KEYS[:metadata]].with_indifferent_access.fetch(:secret)
    headers = { 'Accept' => Mime[:turbo_stream].to_s }

    post create_credential_two_factor_authentication_path(type: 'totp'),
         params: { code: '000000', secret: secret, nickname: 'Retry app' }, headers: headers

    assert_equal Mime[:turbo_stream].to_s, response.media_type
    streams = Nokogiri::HTML5.fragment(response.body).css('turbo-stream')
    assert_equal(['update'], streams.pluck('action'))
    assert_equal(['flash'], streams.pluck('target'))
    assert_includes response.body, I18n.t('two_factor_verification.errors.invalid_code')
    assert_empty @user.totp_credentials

    post create_credential_two_factor_authentication_path(type: 'totp'),
         params: { code: ROTP::TOTP.new(secret).now, secret: secret, nickname: 'Retry app' }, headers: headers

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'totp')
    assert_response :see_other
    assert_equal ['Retry app'], @user.totp_credentials.pluck(:nickname)
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

  test 'SMS enrollment renders its challenge, respects resend cooldown, and persists only after approval' do
    get new_credential_two_factor_authentication_path(type: 'sms')
    assert_response :success
    assert_select 'form[action=?] input[name=phone_number]', create_credential_two_factor_authentication_path(type: 'sms')

    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
    end
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    follow_redirect!
    assert_response :success
    assert_select 'form[action=?] input[name=code]', confirm_pending_sms_credential_two_factor_authentication_path

    TwilioVerifyService.stub(:send_verification, ->(*) { flunk 'The resend cooldown must not contact the provider' }) do
      post resend_pending_sms_code_two_factor_authentication_path
    end
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    assert_match(/wait/i, flash[:alert])

    travel 31.seconds
    post resend_pending_sms_code_two_factor_authentication_path
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    assert_equal 'A new verification code has been sent', flash[:notice]

    assert_difference('SmsCredential.count', 1) do
      assert_difference -> { @user.reload.security_version }, 1 do
        post confirm_pending_sms_credential_two_factor_authentication_path, params: { code: '123456' }
      end
    end
    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    credential = @user.reload.sms_credentials.sole
    assert_equal '555-123-4567', credential.phone_number
    assert_predicate credential, :verified?
    follow_redirect!
    assert_response :success
    assert_select 'h1', 'Setup Complete!'
    assert_includes response.body, 'Your Text Message Verification has been successfully set up.'
  end

  test 'successful SMS setup confirmation redirects Turbo requests to success page' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path

    post confirm_pending_sms_credential_two_factor_authentication_path,
         params: { code: '123456' },
         headers: { 'Accept' => Mime[:turbo_stream].to_s }

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    assert_response :see_other
  end

  test 'invalid and terminal SMS setup confirmations cannot create a credential or replay a cleared challenge' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: { code: '000000' }
    end
    assert_response :unprocessable_content
    assert_select 'h1', text: 'Text Message Verification'
    assert_includes response.body, I18n.t('two_factor_verification.errors.invalid_code')

    TwilioVerifyService.expects(:check_verification).once.returns(success: true, status: 'expired', valid: false)
    assert_no_difference ['SmsCredential.count', 'Event.count', -> { @user.reload.security_version }] do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: { code: '123456' }
      assert_redirected_to new_credential_two_factor_authentication_path(type: 'sms')
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:challenge]]
      post confirm_pending_sms_credential_two_factor_authentication_path, params: { code: '123456' }
      assert_redirected_to new_credential_two_factor_authentication_path(type: 'sms')
    end
  end

  test 'SMS enrollment provider failure uses the shared service-error feedback' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: { phone_number: '555-123-4567' }
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

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '123456'
      }
    end

    credential = @user.reload.sms_credentials.find_by!(phone_number: '555-123-4567')
    assert credential.verified_at.present?
  end

  test 'WebAuthn enrollment rejects another challenge before saving the actual key and consuming its server challenge' do
    original_origins = WebAuthn.configuration.allowed_origins
    original_rp_id = WebAuthn.configuration.rp_id
    WebAuthn.configuration.allowed_origins = ['https://example.com']
    WebAuthn.configuration.rp_id = 'example.com'
    client = WebAuthn::FakeClient.new('https://example.com')

    post webauthn_creation_options_two_factor_authentication_path, as: :json
    assert_response :success
    challenge = response.parsed_body.fetch('challenge')
    wrong_registration = client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com')
    assert_no_difference ['WebauthnCredential.count', 'Event.count', -> { @user.reload.security_version }] do
      post create_credential_two_factor_authentication_path(type: 'webauthn'),
           params: { two_factor_credential: wrong_registration, credential_nickname: 'Office key' }, as: :json
    end
    assert_response :unprocessable_content
    assert_equal 'verification_failed', response.parsed_body['error_code']
    assert_equal challenge, session[TwoFactorAuth::SESSION_KEYS[:challenge]]

    registration = client.create(challenge: challenge, rp_id: 'example.com')
    parsed = WebAuthn::Credential.from_create(registration)
    assert_difference('WebauthnCredential.count', 1) do
      assert_difference -> { @user.reload.security_version }, 1 do
        assert_difference -> { @user.events.where(action: 'mfa_credential_added').count }, 1 do
          post create_credential_two_factor_authentication_path(type: 'webauthn'),
               params: { two_factor_credential: registration, credential_nickname: 'Office key' }, as: :json
        end
      end
    end
    assert_response :success
    credential = @user.reload.webauthn_credentials.sole
    assert_equal [parsed.id, parsed.public_key, 'Office key'], credential.attributes.values_at('external_id', 'public_key', 'nickname')
    assert_equal({ 'status' => 'ok', 'redirect_url' => credential_success_two_factor_authentication_path(type: 'webauthn') },
                 response.parsed_body.slice('status', 'redirect_url'))
    assert_equal credential.id, response.parsed_body.dig('credential', 'id')
    event = @user.events.where(action: 'mfa_credential_added').sole
    assert_equal @user, event.auditable
    assert_equal({ '__service_generated' => true, 'credential_type' => 'webauthn', 'credential_id' => credential.id }, event.metadata)
    assert_equal @user.id, event.user_id
    assert_nil session[TwoFactorAuth::SESSION_KEYS[:challenge]]
  ensure
    WebAuthn.configuration.allowed_origins = original_origins
    WebAuthn.configuration.rp_id = original_rp_id
  end

  { verification: WebAuthn::Error, creation: StandardError }.each do |failure_type, error_class|
    test "WebAuthn enrollment #{failure_type} failure hides exception details at the routed response" do
      sensitive_message = 'private-enrollment@example.test token=private-enrollment-secret'
      failure = error_class.new(sensitive_message)
      logs = []
      log_level = failure_type == :verification ? :warn : :error

      WebAuthn::Credential.stub(:from_create, ->(_attributes) { raise failure }) do
        Rails.logger.stub(log_level, ->(message) { logs << message }) do
          assert_no_difference('WebauthnCredential.count') do
            post create_credential_two_factor_authentication_path(type: 'webauthn'),
                 params: { two_factor_credential: { id: 'key', rawId: 'key', type: 'public-key' } },
                 as: :json
          end
        end
      end

      assert_response :unprocessable_content
      assert_equal({ 'error' => I18n.t('security_key_verification.feedback.failed'),
                     'error_code' => "#{failure_type}_failed" }, response.parsed_body)
      assert(logs.any? { |message| message.include?(error_class.name) })
      assert_not_includes [response.body, logs].join, sensitive_message
      assert_not_includes [response.body, logs].join, 'private-enrollment-secret'
    end
  end

  test 'should require authentication' do
    delete sign_out_path
    assert_redirected_to sign_in_path
    assert_empty @user.sessions

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

  test 'credential removal deletes the selected factor and records its actor and security generation for HTML and Turbo' do
    examples = credential_examples(@user)
    %w[sms webauthn totp].each_with_index do |type, index|
      credential, name = examples.fetch(type)
      if index.positive?
        travel 31.seconds
        post reauthentication_path, params: {
          password: 'password1234', factor_type: 'totp', code: ROTP::TOTP.new(examples.fetch('totp').first.secret).now
        }
        assert_redirected_to edit_profile_path
      end
      headers = type == 'webauthn' ? {} : { 'Accept' => Mime[:turbo_stream].to_s }
      assert_difference -> { credential.class.count }, -1 do
        assert_difference -> { @user.reload.security_version }, 1 do
          assert_difference -> { @user.events.where(action: 'mfa_credential_removed').count }, 1 do
            delete destroy_credential_two_factor_authentication_path(type: type, id: credential.id), headers: headers
          end
        end
      end
      if type == 'webauthn'
        assert_redirected_to edit_profile_path
        assert_equal "#{name} removed successfully", flash[:notice]
      else
        assert_response :success
        assert_select 'turbo-stream[action=remove][target=?]', ActionView::RecordIdentifier.dom_id(credential)
        assert_select 'turbo-stream[action=update][target=flash]', text: /#{Regexp.escape(name)} removed successfully/
      end
      event = @user.events.where(action: 'mfa_credential_removed').order(:id).last
      assert_equal @user, event.auditable
      assert_equal [@user.id, type, credential.id], [event.user_id, *event.metadata.values_at('credential_type', 'credential_id')]
    end
  end

  test 'credential removal hides foreign and missing factor IDs and rejects unknown factor types without changing authority' do
    other_user = create(:constituent)
    other_user.update_column(:webauthn_id, WebAuthn.generate_user_id)
    credential_examples(other_user).each do |type, (credential, name)|
      [credential.id, 0].each do |id|
        assert_no_difference ['WebauthnCredential.count', 'TotpCredential.count', 'SmsCredential.count', 'Event.count',
                              -> { @user.reload.security_version }, -> { other_user.reload.security_version }] do
          delete destroy_credential_two_factor_authentication_path(type: type, id: id)
        end
        assert_redirected_to edit_profile_path
        assert_equal "#{name} not found", flash[:alert]
      end
      assert credential.class.exists?(credential.id), "#{type} must remain owned by the other account"
    end

    assert_no_difference ['WebauthnCredential.count', 'TotpCredential.count', 'SmsCredential.count', 'Event.count',
                          -> { @user.reload.security_version }] do
      delete destroy_credential_two_factor_authentication_path(type: 'unknown', id: other_user.id)
    end
    assert_redirected_to edit_profile_path
    assert_equal 'Invalid credential type', flash[:alert]
  end

  private

  def credential_examples(user)
    {
      'webauthn' => [create(:webauthn_credential, user: user, nickname: 'Security key'), 'Security key'],
      'totp' => [user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Authenticator app'), 'Authenticator app'],
      'sms' => [user.sms_credentials.create!(phone_number: '555-123-4567', verified_at: Time.current), 'SMS verification']
    }
  end
end
