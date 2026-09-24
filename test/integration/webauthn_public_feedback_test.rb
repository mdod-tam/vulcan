# frozen_string_literal: true

require 'test_helper'
require 'webauthn/fake_client'

class WebauthnPublicFeedbackTest < ActionDispatch::IntegrationTest
  setup do
    @original_origins = WebAuthn.configuration.allowed_origins
    @original_rp_id = WebAuthn.configuration.rp_id
    WebAuthn.configuration.allowed_origins = ['https://example.com']
    WebAuthn.configuration.rp_id = 'example.com'
    @client = WebAuthn::FakeClient.new('https://example.com')
    @user = create(:constituent, locale: :en)
    registration = @client.create(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com')
    credential = WebAuthn::Credential.from_create(registration)
    @credential = create(:webauthn_credential, user: @user, external_id: credential.id, public_key: credential.public_key)
  end

  teardown do
    WebAuthn.configuration.allowed_origins = @original_origins
    WebAuthn.configuration.rp_id = @original_rp_id
  end

  %i[en es].each do |locale|
    test "credential lookup, challenge and verifier failures have identical public results in #{locale}" do
      post sign_in_path(locale: locale), params: { contact: @user.email, password: 'password123' }
      assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn', locale: locale)
      follow_redirect!
      assert_select 'html[lang=?]', locale.to_s
      assert_select 'h1', I18n.t('security_key_verification.page.heading', locale: locale)
      assert_select 'form[action=?]', verification_options_two_factor_authentication_path(type: 'webauthn', locale: locale)
      assert_select '[data-credential-authenticator-verification-url-value=?]',
                    process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale)

      logs = []
      results = []
      Rails.logger.stub(:warn, ->(message) { logs << message }) do
        %i[unknown_credential wrong_challenge bad_signature malformed_signature].each do |failure|
          assertion = assertion_for(locale)
          case failure
          when :unknown_credential
            assertion['id'] = assertion['rawId'] = Base64.urlsafe_encode64('unknown-key', padding: false)
          when :wrong_challenge
            assertion = @client.get(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com', user_verified: true)
          when :bad_signature
            signature = Base64.urlsafe_decode64(assertion['response']['signature'])
            signature.setbyte(-1, signature.getbyte(-1) ^ 1)
            assertion['response']['signature'] = Base64.urlsafe_encode64(signature, padding: false)
          when :malformed_signature
            assertion['response']['signature'] = Base64.urlsafe_encode64('invalid signature', padding: false)
          end

          assert_no_difference('Session.count') do
            post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
                 params: { two_factor_authentication: assertion }, as: :json
          end
          assert_response :unprocessable_content
          results << [response.status, response.parsed_body]
          assert_equal 0, @credential.reload.sign_count
        end
      end

      assert_equal 1, results.uniq.length
      assert_equal({ 'error' => I18n.t('security_key_verification.feedback.failed', locale: locale),
                     'error_code' => 'verification_failed' }, results.first.last)
      assert(logs.any? { |line| line.include?('Credential not found') })
      assert_equal(2, logs.count { |line| line.include?('WebAuthn::') })
      assert_equal(1, logs.count { |line| line.include?('OpenSSL::PKey::PKeyError') })

      assertion = assertion_for(locale)
      assert_difference('Session.count', 1) do
        post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
             params: { two_factor_authentication: assertion }, as: :json
      end
      assert_response :success
      assert_equal 'success', response.parsed_body['status']
      assert_equal 1, @credential.reload.sign_count
    end
  end

  %w[text/html text/vnd.turbo-stream.html].each do |format|
    test "#{format} verification errors use the same translated public message" do
      post sign_in_path(locale: :es), params: { contact: @user.email, password: 'password123' }
      %i[unknown_credential wrong_challenge].each do |failure|
        assertion = assertion_for(:es)
        if failure == :unknown_credential
          assertion['id'] = assertion['rawId'] = Base64.urlsafe_encode64('unknown-key', padding: false)
        else
          assertion = @client.get(challenge: SecureRandom.urlsafe_base64(32), rp_id: 'example.com', user_verified: true)
        end
        post process_verification_two_factor_authentication_path(type: 'webauthn', locale: :es),
             params: { two_factor_authentication: assertion }, headers: { 'Accept' => format }
        assert_response(format == 'text/html' ? :unprocessable_content : :success)
        assert_includes response.body, I18n.t('security_key_verification.feedback.failed', locale: :es)
        assert_not_includes response.body, 'Credential not found'
        assert_not_includes response.body, 'WebAuthn::'
      end
    end
  end

  test 'invalid locale falls back to the public default instead of the account locale' do
    @user.update!(locale: :es)
    post sign_in_path(locale: 'unsupported'), params: { contact: @user.email, password: 'password123' }
    assert_redirected_to verify_method_two_factor_authentication_path(type: 'webauthn')
    follow_redirect!
    assert_select 'html[lang=en]'
    assert_select 'h1', I18n.t('security_key_verification.page.heading', locale: :en)
  end

  %i[en es].each do |locale|
    test "missing MFA user returns localized code errors with status 422 in #{locale}" do
      @user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
      @user.sms_credentials.create!(phone_number: '410-555-1234', verified_at: Time.current)
      post sign_in_path(locale: locale), params: { contact: @user.email, password: 'password123' }
      assert_redirected_to verify_two_factor_authentication_path(locale: locale)
      @user.update!(status: :suspended)

      %w[totp sms].each do |type|
        assert_no_difference('Session.count') do
          post process_verification_two_factor_authentication_path(type: type, locale: locale), params: { code: '123456' }, as: :json
        end
        assert_response :unprocessable_content
        assert_equal({ 'error' => I18n.t('two_factor_verification.errors.user_session', locale: locale),
                       'error_code' => 'user_session' }, response.parsed_body)
      end
    end

    test "missing MFA user keeps sign-in guidance for WebAuthn responses in #{locale}" do
      post sign_in_path(locale: locale), params: { contact: @user.email, password: 'password123' }
      assertion = assertion_for(locale)
      @user.update!(status: :suspended)
      message = I18n.t('two_factor_verification.errors.user_session', locale: locale)

      %w[application/json text/html text/vnd.turbo-stream.html].each do |format|
        assert_no_difference('Session.count') do
          post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
               params: { two_factor_authentication: assertion }, headers: { 'Accept' => format }
        end
        if format == 'application/json'
          assert_response :unprocessable_content
          assert_equal({ 'error' => message, 'error_code' => 'user_session' }, response.parsed_body)
        else
          assert_redirected_to sign_in_path(locale: locale)
          assert_equal message, flash[:alert]
        end
        assert_equal 0, @credential.reload.sign_count
      end
    end

    test "verified key with session failure has a distinct localized response in #{locale}" do
      post sign_in_path(locale: locale), params: { contact: @user.email, password: 'password123' }
      assertion = assertion_for(locale)
      TwoFactorAuthenticationsController.any_instance.expects(:_create_and_set_session_cookie).returns(nil)

      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'webauthn', locale: locale),
             params: { two_factor_authentication: assertion }, as: :json
      end
      assert_response :unprocessable_content
      assert_equal 'session_failed', response.parsed_body['error_code']
      assert_equal I18n.t('security_key_verification.feedback.session_failed', locale: locale), response.parsed_body['error']
      assert_equal 1, @credential.reload.sign_count
    end
  end

  test 'locale URL defaults are not routable controller actions' do
    [SessionsController, TwoFactorAuthenticationsController].each do |controller|
      assert_not_includes controller.action_methods, 'default_url_options'
    end
  end

  private

  def assertion_for(locale)
    get verification_options_two_factor_authentication_path(type: 'webauthn', locale: locale), as: :json
    assert_response :success
    @client.get(challenge: response.parsed_body.fetch('challenge'), rp_id: 'example.com', user_verified: true, sign_count: 1)
  end
end
