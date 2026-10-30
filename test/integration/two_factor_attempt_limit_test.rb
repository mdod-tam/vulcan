# frozen_string_literal: true

require 'test_helper'

# Real password and MFA requests prove that a fresh browser/password step cannot reset the budget.
class TwoFactorAttemptLimitTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @user = create(:constituent)
    @credential = @user.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Authenticator')
  end

  test 'TOTP failures persist across browser sessions and IP addresses until the account window ends' do
    freeze_time do
      UserAuthentication::TOTP_MAX_ATTEMPTS.times do |attempt|
        reset!
        post sign_in_path, params: { email: @user.email, password: 'password1234' }
        assert_no_difference('Session.count') do
          post process_verification_two_factor_authentication_path(type: 'totp'),
               params: { code: 'invalid-code' }, as: :json,
               headers: { 'REMOTE_ADDR' => "192.0.2.#{attempt + 1}" }
        end
        assert_equal attempt + 1, @user.reload.totp_failed_attempts
      end
      assert_equal 'rate_limited', response.parsed_body.fetch('error_code')
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]

      reset!
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
      end
      assert_equal 'rate_limited', response.parsed_body.fetch('error_code')
      assert_equal UserAuthentication::TOTP_MAX_ATTEMPTS, @user.reload.totp_failed_attempts

      travel UserAuthentication::TOTP_ATTEMPT_PERIOD
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      assert_difference('Session.count', 1) do
        post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
      end
      assert_response :success
      assert_equal 0, @user.reload.totp_failed_attempts
      assert_nil @user.totp_attempt_window_started_at
    end
  end

  %i[en es].each do |locale|
    test "exhausting TOTP attempts redirects with #{locale} restart guidance" do
      @user.update!(totp_failed_attempts: UserAuthentication::TOTP_MAX_ATTEMPTS - 1,
                    totp_attempt_window_started_at: Time.current)
      post sign_in_path(locale: locale), params: { email: @user.email, password: 'password1234' }

      post process_verification_two_factor_authentication_path(type: 'totp', locale: locale), params: { code: 'invalid-code' }

      assert_redirected_to sign_in_path(locale: locale)
      assert_equal I18n.t('two_factor_verification.errors.totp_rate_limited', locale: locale), flash[:alert]
      follow_redirect!
      assert_select '[data-testid="flash-alert"]', text: I18n.t('two_factor_verification.errors.totp_rate_limited', locale: locale)
    end
  end

  test 'TOTP bookkeeping counts and clears failures independently of profile validation' do
    @user.update_columns(first_name: nil)
    assert_not @user.reload.valid?
    assert_includes @user.errors.attribute_names, :first_name
    post sign_in_path, params: { email: @user.email, password: 'password1234' }
    post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: 'invalid-code' }, as: :json
    assert_equal 1, @user.reload.totp_failed_attempts
    assert_not_nil @user.totp_attempt_window_started_at

    assert_difference('Session.count', 1) do
      post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
    end

    assert_response :success
    assert_equal 0, @user.reload.totp_failed_attempts
    assert_nil @user.totp_attempt_window_started_at
    assert_nil @user.first_name
  end

  test 'malformed nonblank codes consume attempts and return a controlled refusal' do
    post sign_in_path, params: { email: @user.email, password: 'password1234' }

    [123_456, ['123456'], { value: '123456' }, '1' * 100_000].each_with_index do |code, index|
      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: code }, as: :json
      end

      assert_response :unprocessable_content
      assert_equal I18n.t('two_factor_verification.errors.invalid_code'), response.parsed_body.fetch('error')
      assert_equal index + 1, @user.reload.totp_failed_attempts
    end
  end

  test 'the pending password step expires before a correct second factor can create a session' do
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      travel UserAuthentication::TWO_FACTOR_SIGN_IN_EXPIRY + 1.second

      assert_no_difference('Session.count') do
        post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
      end

      assert_equal 'user_session', response.parsed_body.fetch('error_code')
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
      assert_nil session[TwoFactorAuth::SESSION_KEYS[:sign_in_token]]
    end
  end

  test 'verification IP throttle uses a shared cache budget and expires after a minute' do
    store = ActiveSupport::Cache::MemoryStore.new
    native_store = TwoFactorAuthenticationsController.cache_store
    native_store.stub(:increment, ->(*args, **options) { store.increment(*args, **options) }) do
      freeze_time do
        30.times do
          post sign_in_path, params: { email: @user.email, password: 'password1234' }
          post process_verification_two_factor_authentication_path(type: 'unknown'), as: :json
          assert_response :unprocessable_content
        end
        post sign_in_path, params: { email: @user.email, password: 'password1234' }
        assert_no_difference('Session.count') do
          post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
        end
        assert_response :too_many_requests
        assert_equal 'rate_limited', response.parsed_body.fetch('error_code')
        assert_includes response.headers.fetch('Cache-Control'), 'no-store'
        assert_nil session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]

        travel 1.minute + 1.second
        post sign_in_path, params: { email: @user.email, password: 'password1234' }
        assert_difference('Session.count', 1) do
          post process_verification_two_factor_authentication_path(type: 'totp'), params: { code: valid_code }, as: :json
        end
        assert_response :success
      end
    end
  end

  private

  def valid_code
    ROTP::TOTP.new(@credential.secret).now
  end
end
