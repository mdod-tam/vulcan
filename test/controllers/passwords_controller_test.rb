# frozen_string_literal: true

require 'test_helper'

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @start_time = Time.current

    create_basic_email_templates

    @user = create(:constituent, password: 'password1234', password_confirmation: 'password1234')
    @original_password_digest = @user.password_digest
    @system_audit_actor = User.find_by(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL) ||
                          create(:admin, email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)

    sign_in_for_integration_test(@user)
  end

  def teardown
    sign_out if respond_to?(:sign_out)

    @execution_time = Time.current - @start_time
    puts "PasswordsControllerTest #{name} took #{@execution_time.round(2)}s"
  end

  %i[phone email].each do |contact|
    test "account recovery configuration classification for #{contact}" do
      @user.update!(phone_type: 'text')
      FeatureFlag.where(name: EmailDelivery.category_control(:account_security)).delete_all
      SmsService.expects(:send_message).never
      assert_difference -> { Event.where(action: 'email_delivery_configuration_error').count }, 1 do
        assert_difference -> { Event.where(action: 'account_access_instructions_configuration_error', auditable: @user).count }, 1 do
          post password_path, params: { contact: @user.public_send(contact) }
        end
      end
      assert_redirected_to sign_in_path
    end
  end

  def test_should_get_edit
    get edit_password_path
    assert_response :success
    assert_select 'form[action=?]', password_path
    assert_select 'h2', text: 'Change Password'
    assert_select 'label', text: 'Current Password'
  end

  def test_should_redirect_unauthenticated_edit_without_token_to_account_access
    sign_out if respond_to?(:sign_out)

    get edit_password_path

    assert_redirected_to new_password_path
    assert_equal 'Use your account access link to reset your password.', flash[:alert]
  end

  def test_should_redirect_unauthenticated_update_without_token_to_account_access
    sign_out if respond_to?(:sign_out)

    patch password_path, params: {
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to new_password_path
    assert_equal 'Use your account access link to reset your password.', flash[:alert]
  end

  def test_should_send_account_access_email_for_existing_email
    sign_out
    assert_difference -> { Event.where(action: 'account_access_instructions_sent', auditable: @user).count }, 1 do
      assert_enqueued_emails 1 do
        post password_path, params: { contact: @user.email }
      end
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    event = @user.audit_events.find_by!(action: 'account_access_instructions_sent')
    assert_equal @system_audit_actor, event.user
    assert_equal @user, event.auditable
    assert_equal 'public_unauthenticated', event.metadata['public_audit_actor']
  end

  test 'missing system actor does not attribute anonymous account access to the account holder' do
    sign_out
    Current.set(user: @system_audit_actor) do
      @system_audit_actor.update!(email: 'unconfigured-audit@example.test')
    end

    logs = capture_rails_logs do
      assert_no_difference 'User.count' do
        assert_no_difference -> { Event.where(action: 'account_access_instructions_sent').count } do
          assert_enqueued_emails 1 do
            post password_path, params: { contact: @user.email }
          end
        end
      end
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_includes logs, "skipped audit 'account_access_instructions_sent'"
    assert_not_includes logs, @user.email
  end

  def test_should_send_account_access_sms_for_existing_phone
    @user.update!(phone_type: 'text')

    SmsService.expects(:send_message)
              .with(@user.phone,
                    regexp_matches(%r{MAT account access link to set your password: https?://\S+ This link expires in 20 minutes\.}),
                    sensitive: true,
                    action: 'SmsService#account_access',
                    delivery_context: has_entries('mail_action' => 'SmsService#account_access'),
                    context: { recipient_id: @user.id, recipient_channel: 'account_access_sms' })
              .returns(true)

    assert_difference -> { Event.where(action: 'account_access_instructions_sent', auditable: @user).count }, 1 do
      assert_no_enqueued_emails do
        post password_path, params: { contact: @user.phone }
      end
    end

    assert_redirected_to sign_in_path
  end

  def test_account_access_sms_reset_url_uses_configured_host_not_request_host
    original_default_url_options = Rails.application.config.action_mailer.default_url_options&.dup
    Rails.application.config.action_mailer.default_url_options = { host: 'example.com' }
    @user.update!(phone_type: 'text')

    SmsService.expects(:send_message)
              .with(@user.phone,
                    regexp_matches(%r{MAT account access link to set your password: http://example\.com/password/edit\?locale=en&token=\S+ This link expires in 20 minutes\.}),
                    sensitive: true,
                    action: 'SmsService#account_access',
                    delivery_context: has_entries('mail_action' => 'SmsService#account_access'),
                    context: { recipient_id: @user.id, recipient_channel: 'account_access_sms' })
              .returns(true)

    post password_path, params: { contact: @user.phone }, headers: { 'Host' => 'attacker.example' }

    assert_redirected_to sign_in_path
  ensure
    Rails.application.config.action_mailer.default_url_options = original_default_url_options
  end

  def test_should_return_generic_confirmation_when_sms_delivery_fails
    @user.update!(phone_type: 'text')

    SmsService.expects(:send_message).raises(StandardError, 'invalid number')

    assert_difference -> { Event.where(action: 'account_access_instructions_delivery_failed', auditable: @user).count }, 1 do
      post password_path, params: { contact: @user.phone }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_sms_delivery_failure_logs_redact_account_access_reset_url
    @user.update!(phone_type: 'text')
    reset_url = 'https://example.test/password/edit?token=secret-reset-token'

    SmsService.expects(:send_message).raises(StandardError.new("provider echoed #{reset_url}"))

    logs = capture_rails_logs do
      assert_difference -> { Event.where(action: 'account_access_instructions_delivery_failed', auditable: @user).count }, 1 do
        post password_path, params: { contact: @user.phone }
      end
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_includes logs, 'StandardError'
    assert_not_includes logs, reset_url
    assert_not_includes logs, 'secret-reset-token'
  end

  def test_account_access_confirmation_uses_request_locale
    sign_out if respond_to?(:sign_out)

    post password_path, params: { contact: 'unknown@example.com', locale: 'es' }

    assert_redirected_to sign_in_path(locale: 'es')
    assert_equal account_access_confirmation_message(locale: :es), flash[:notice]
  end

  def test_account_access_sms_link_carries_the_recipients_locale
    @user.update!(phone_type: 'text', locale: 'es')

    SmsService.expects(:send_message)
              .with(@user.phone,
                    regexp_matches(%r{password/edit\?locale=es&token=\S+}),
                    sensitive: true,
                    action: 'SmsService#account_access',
                    delivery_context: has_entries('mail_action' => 'SmsService#account_access'),
                    context: { recipient_id: @user.id, recipient_channel: 'account_access_sms' })
              .returns(true)

    post password_path, params: { contact: @user.phone }
  end

  def test_reset_page_follows_the_link_locale
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    get edit_password_path(token: token, locale: 'es')

    assert_response :success
    assert_select 'html[lang=es]'
    assert_select 'h2', text: I18n.t('passwords.edit.reset', locale: :es)
    assert_select 'label', text: I18n.t('passwords.edit.new_password', locale: :es)
    assert_select 'label', text: I18n.t('passwords.edit.confirm_password', locale: :es)
    assert_select 'input[type=submit][value=?]', I18n.t('passwords.edit.reset', locale: :es)
    assert_select 'input[name=locale][value=es]'
    assert_select 'a[href=?]', sign_in_path(locale: 'es'), text: I18n.t('passwords.edit.cancel', locale: :es)
  end

  def test_reset_page_never_takes_its_language_from_the_account
    @user.update!(locale: 'es')
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    get edit_password_path(token: token)

    assert_select 'html[lang=en]'
    assert_select 'h2', text: 'Reset Password'
  end

  def test_failed_reset_submissions_stay_in_the_form_locale
    @user.update_columns(failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current)
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    patch password_path, params: { token: token, locale: 'es', password: 'NewValid*Password123', password_confirmation: 'Different*Password123' }

    assert_response :unprocessable_content
    assert_select '[data-testid="flash-alert"]', text: I18n.t('passwords.mismatch', locale: :es), count: 1
    assert_select 'html[lang=es]'
    assert_select 'input[name=locale][value=es]'

    patch password_path, params: { token: token, locale: 'es', password: 'short', password_confirmation: 'short' }

    assert_response :unprocessable_content
    assert_equal 'No se pudo actualizar la contraseña. Contraseña tiene muy pocos caracteres (mínimo 12).', flash.now[:alert]
    assert_equal @original_password_digest, @user.reload.password_digest
    assert_predicate @user, :account_locked?
    assert_equal UserAuthentication::MAX_LOGIN_ATTEMPTS, @user.failed_attempts
  end

  def test_successful_reset_redirects_to_sign_in_in_the_form_locale
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    patch password_path, params: { token: token, locale: 'es', password: 'TokenReset*Password123', password_confirmation: 'TokenReset*Password123' }

    assert_redirected_to sign_in_path(locale: 'es')
    assert_equal I18n.t('passwords.updated', locale: :es), flash[:notice]
    assert @user.reload.authenticate('TokenReset*Password123')
  end

  def test_invalid_and_missing_reset_links_redirect_in_the_request_locale
    sign_out if respond_to?(:sign_out)

    get edit_password_path(token: 'invalid-token', locale: 'es')
    assert_redirected_to new_password_path(locale: 'es')
    assert_equal I18n.t('passwords.invalid_reset_link', locale: :es), flash[:alert]

    get edit_password_path(locale: 'es')
    assert_redirected_to new_password_path(locale: 'es')
    assert_equal I18n.t('passwords.account_access_required', locale: :es), flash[:alert]

    get edit_password_path(token: 'invalid-token')
    assert_redirected_to new_password_path
    assert_equal 'Invalid or expired reset link.', flash[:alert]
  end

  def test_should_rate_limit_repeated_account_access_sms_requests
    @user.update!(phone_type: 'text')

    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    limit = 2
    set_auth_rate_limit_policy('account_access_rate_limit_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_limit_contact_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_limit_user_ip', limit)
    set_auth_rate_limit_policy('account_access_rate_period', 1)

    SmsService.expects(:send_message).times(limit).returns(true)

    (limit + 1).times do
      post password_path, params: { contact: @user.phone }
    end

    assert_equal 1, Event.where(action: 'account_access_instructions_rate_limited', auditable: @user).count
    assert_budget_prefix_present('auth_rate_limit:account_access:user_ip:')
    assert_budget_prefix_absent('account_access:')
  ensure
    Rails.cache = old_cache
  end

  def test_unknown_account_access_contact_rate_limit_uses_public_audit_without_raw_contact
    sign_out if respond_to?(:sign_out)

    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    contact = "unknown-access-#{SecureRandom.hex(4)}@example.com"
    set_auth_rate_limit_policy('account_access_rate_limit_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_limit_contact_ip', 1)
    set_auth_rate_limit_policy('account_access_rate_limit_user_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_period', 1)

    post password_path, params: { contact: contact }

    assert_difference -> { Event.where(action: 'account_access_instructions_rate_limited', user: @system_audit_actor).count }, 1 do
      assert_no_enqueued_emails do
        post password_path, params: { contact: contact }
      end
    end

    event = Event.where(action: 'account_access_instructions_rate_limited', user: @system_audit_actor).last
    assert_equal 'contact_ip', event.metadata['rate_limit_scope']
    assert event.metadata['request_ip_digest'].present?
    assert event.metadata['submitted_contact_digest'].present?
    assert_not_includes event.metadata.values.join(' '), contact
    assert_budget_prefix_present('auth_rate_limit:account_access:contact_ip:')
    assert_budget_prefix_absent('account_access:')
  ensure
    Rails.cache = old_cache
  end

  def test_should_return_generic_confirmation_for_unknown_contact
    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: 'unknown@example.com' }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_should_update_password_with_valid_token_without_current_password
    @user.update_columns(failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current,
                         totp_failed_attempts: 3, totp_attempt_window_started_at: Time.current)
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    get edit_password_path(token: token)
    assert_response :success
    assert_select 'h2', text: 'Reset Password'
    assert_select 'input[name=token][value=?]', token
    assert_select 'label', { text: 'Current Password', count: 0 }

    patch password_path, params: {
      token: token,
      password: 'TokenReset*Password123',
      password_confirmation: 'TokenReset*Password123'
    }

    assert_redirected_to sign_in_path
    assert_equal 'Password successfully updated.', flash[:notice]
    assert @user.reload.authenticate('TokenReset*Password123')
    assert_not_predicate @user, :account_locked?
    assert_equal 0, @user.failed_attempts
    assert_equal 3, @user.totp_failed_attempts
    assert_empty @user.sessions
  end

  test 'blank password resets preserve account authority and allow a valid retry' do
    @user.update!(force_password_change: true, failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current)
    token = @user.generate_token_for(:password_reset)
    original_security_version = @user.security_version
    original_locked_at = @user.locked_at
    sign_out
    @user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Outstanding reset-test session')
    original_session_ids = @user.sessions.ids

    blank_password_submissions.each do |password_params|
      patch password_path, params: { token: token, locale: 'es' }.merge(password_params)

      assert_response :unprocessable_content
      assert_select 'html[lang=es]'
      assert_select '[data-testid="flash-alert"]', text: /no puede estar en blanco/
      @user.reload
      assert_equal @original_password_digest, @user.password_digest
      assert_predicate @user, :force_password_change?
      assert_equal original_security_version, @user.security_version
      assert_equal original_session_ids, @user.sessions.ids
      assert_equal original_locked_at, @user.locked_at
      assert_equal UserAuthentication::MAX_LOGIN_ATTEMPTS, @user.failed_attempts
      assert_equal @user.id, User.find_by_token_for(:password_reset, token)&.id
    end

    patch password_path, params: { token: token, password: 'TokenReset*Password123', password_confirmation: 'TokenReset*Password123' }

    assert_redirected_to sign_in_path
    assert @user.reload.authenticate('TokenReset*Password123')
    assert_not_predicate @user, :force_password_change?
    assert_equal original_security_version + 1, @user.security_version
    assert_empty @user.sessions
    assert_nil @user.locked_at
    assert_equal 0, @user.failed_attempts
    assert_nil User.find_by_token_for(:password_reset, token)
  end

  def test_password_reset_token_cannot_be_reused_after_successful_update
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    patch password_path, params: {
      token: token,
      password: 'TokenReset*Password123',
      password_confirmation: 'TokenReset*Password123'
    }

    assert_redirected_to sign_in_path
    assert @user.reload.authenticate('TokenReset*Password123')

    patch password_path, params: {
      token: token,
      password: 'ReplayReset*Password123',
      password_confirmation: 'ReplayReset*Password123'
    }

    assert_redirected_to new_password_path
    assert_equal 'Invalid or expired reset link.', flash[:alert]
    follow_redirect!
    assert_select '[data-testid="flash-alert"]', text: 'Invalid or expired reset link.', count: 1
    assert_not @user.reload.authenticate('ReplayReset*Password123')
  end

  def test_generated_password_reset_token_is_invalid_after_normalized_email_changes
    token = @user.generate_token_for(:password_reset)

    @user.update!(email: "changed-#{SecureRandom.hex(4)}@example.com")

    assert_nil User.find_by_token_for(:password_reset, token)
  end

  # SMS delivers reset links. A phone change must revoke links sent to the old number.
  def test_generated_password_reset_token_is_invalid_after_phone_changes
    @user.update!(phone: '555-867-5309')
    token = @user.generate_token_for(:password_reset)

    @user.update!(phone: '555-234-5678')

    assert_nil User.find_by_token_for(:password_reset, token)
  end

  def test_generated_password_reset_token_survives_a_non_contact_change
    token = @user.generate_token_for(:password_reset)

    @user.update!(first_name: "Renamed#{SecureRandom.hex(2)}")

    assert_equal @user.id, User.find_by_token_for(:password_reset, token)&.id
  end

  # Storage and the reset fingerprint both normalize ten-digit US numbers, so format-only changes preserve reset authority.
  def test_generated_password_reset_token_survives_a_cosmetic_phone_reformat
    @user.update!(phone: '555-867-5309')
    token = @user.generate_token_for(:password_reset)

    @user.update!(phone: '5558675309')

    assert_equal @user.id, User.find_by_token_for(:password_reset, token)&.id
  end

  def test_should_update_password_with_valid_inputs
    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to constituent_portal_dashboard_path
    follow_redirect!
    assert_equal 'Password successfully updated.', flash[:notice]

    @user.reload
    assert_not_equal @original_password_digest, @user.password_digest
  end

  [false, true].each do |rotation_required|
    test "blank password changes preserve account authority when rotation is #{rotation_required}" do
      @user.update!(force_password_change: rotation_required)
      original_security_version = @user.security_version
      original_session_ids = @user.sessions.ids

      blank_password_submissions.each do |password_params|
        patch password_path, params: { password_challenge: 'password1234' }.merge(password_params)

        assert_response :unprocessable_content
        assert_select '[data-testid="flash-alert"]', text: /can't be blank/
        @user.reload
        assert_equal @original_password_digest, @user.password_digest
        assert_equal rotation_required, @user.force_password_change?
        assert_equal original_security_version, @user.security_version
        assert_equal original_session_ids, @user.sessions.ids
      end

      if rotation_required
        get constituent_portal_dashboard_path
        assert_redirected_to edit_password_path
      end

      patch password_path, params: {
        password_challenge: 'password1234', password: 'NewValid*Password123', password_confirmation: 'NewValid*Password123'
      }

      assert_redirected_to(rotation_required ? welcome_path : constituent_portal_dashboard_path)
      assert @user.reload.authenticate('NewValid*Password123')
      assert_not_predicate @user, :force_password_change?
      assert_equal original_security_version + 1, @user.security_version
      assert_empty original_session_ids & @user.sessions.ids
    end
  end

  def test_password_update_for_a_locked_account_ends_at_sign_in_without_a_new_session
    @user.update_columns(failed_attempts: UserAuthentication::MAX_LOGIN_ATTEMPTS, locked_at: Time.current)

    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to sign_in_path
    assert_equal 'Password successfully updated. Sign-in is paused for up to 60 minutes after too many failed attempts. ' \
                 'Try again after that.', flash[:notice]
    @user.reload
    assert @user.authenticate('NewValid*Password123')
    assert_equal 0, @user.sessions.count
    assert_predicate @user, :account_locked?
  end

  test 'password update explains a lock applied after the request loaded the user' do
    constructor = Users::PasswordUpdateService.method(:new)
    lock_before_service = lambda do |*arguments|
      # The request has loaded current_user; another login attempt now locks a separate instance.
      other_request_user = User.find(@user.id)
      UserAuthentication::MAX_LOGIN_ATTEMPTS.times { other_request_user.record_failed_login! }
      constructor.call(*arguments)
    end

    Users::PasswordUpdateService.stub(:new, lock_before_service) do
      patch password_path, params: {
        password_challenge: 'password1234',
        password: 'NewValid*Password123',
        password_confirmation: 'NewValid*Password123'
      }
    end

    assert_redirected_to sign_in_path
    @user.reload
    assert @user.authenticate('NewValid*Password123')
    assert_equal 0, @user.sessions.count
    assert_predicate @user, :account_locked?
    assert_equal I18n.t('passwords.updated_while_locked', minutes: 60), flash[:notice]
  end

  def test_should_redirect_turbo_stream_password_update_to_dashboard
    patch password_path,
          params: {
            password_challenge: 'password1234',
            password: 'NewValid*Password123',
            password_confirmation: 'NewValid*Password123'
          },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    assert_redirected_to constituent_portal_dashboard_path
    assert_response :see_other
  end

  def test_should_redirect_forced_password_change_without_mfa_to_welcome
    @user.update!(force_password_change: true)

    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to welcome_path
    assert_not @user.reload.force_password_change?
  end

  def test_should_redirect_required_role_without_mfa_to_setup_after_password_update
    sign_out
    admin = create(:admin, password: 'password1234', password_confirmation: 'password1234')
    sign_in_for_integration_test(admin)

    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to setup_two_factor_authentication_path
  end

  def test_should_not_update_password_with_wrong_current_password
    patch password_path, params: {
      password_challenge: 'wrongpassword',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_response :unprocessable_content
    assert_equal 'Current password is incorrect.', flash.now[:alert]
    assert_select '[data-testid="flash-alert"]', text: 'Current password is incorrect.', count: 1

    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end

  def test_should_not_update_password_with_mismatched_confirmation
    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'NewValid*Password123',
      password_confirmation: 'DifferentPassword123'
    }

    assert_response :unprocessable_content
    assert_equal 'New password and confirmation do not match.', flash.now[:alert]
    assert_select '[data-testid="flash-alert"]', text: 'New password and confirmation do not match.', count: 1

    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end

  def test_should_not_update_password_with_invalid_new_password
    patch password_path, params: {
      password_challenge: 'password1234',
      password: 'short',
      password_confirmation: 'short'
    }

    assert_response :unprocessable_content
    assert_equal 'Unable to update password. Password is too short (minimum is 12 characters).', flash.now[:alert]

    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end

  def test_phone_only_record_does_not_receive_account_access
    sign_out if respond_to?(:sign_out)

    phone = '410-555-0177'
    Current.paper_context = true
    begin
      Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyAccess',
        phone: phone,
        phone_type: 'text',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password1234', password_confirmation: 'password1234',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: phone }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_system_email_does_not_fall_through_to_phone_for_account_access
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local",
                  phone: '410-555-0166',
                  password: 'password1234',
                  password_confirmation: 'password1234')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: user.email }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_placeholder_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  phone: '000-000-4321',
                  email: "real.#{SecureRandom.hex(3)}@example.com",
                  password: 'password1234',
                  password_confirmation: 'password1234')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: user.phone }
    end

    assert_redirected_to sign_in_path
  end

  def test_guardian_generated_synthetic_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    create(:constituent,
           phone: '000-345-6789',
           email: "real.#{SecureRandom.hex(3)}@example.com",
           password: 'password1234',
           password_confirmation: 'password1234')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '0003456789' }
    end

    assert_redirected_to sign_in_path
  end

  def test_account_access_accepts_email_with_surrounding_whitespace
    sign_out if respond_to?(:sign_out)

    assert_enqueued_emails 1 do
      post password_path, params: { contact: "  #{@user.email}  " }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_voice_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  phone: '410-555-0144',
                  phone_type: 'voice',
                  email: "voice.#{SecureRandom.hex(3)}@example.com",
                  password: 'password1234',
                  password_confirmation: 'password1234')

    SmsService.expects(:send_message).never

    assert_difference -> { Event.where(action: 'account_access_instructions_delivery_unavailable', auditable: user).count }, 1 do
      assert_no_enqueued_emails do
        post password_path, params: { contact: user.phone }
      end
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_delivery_unavailable_account_access_audits_stop_after_rate_limit
    sign_out if respond_to?(:sign_out)

    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    user = create(:constituent,
                  phone: '410-555-0145',
                  phone_type: 'voice',
                  email: "voice-rate-limit-#{SecureRandom.hex(3)}@example.com",
                  password: 'password1234',
                  password_confirmation: 'password1234')
    limit = 2
    set_auth_rate_limit_policy('account_access_rate_limit_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_limit_contact_ip', 10)
    set_auth_rate_limit_policy('account_access_rate_limit_user_ip', limit)
    set_auth_rate_limit_policy('account_access_rate_period', 1)

    SmsService.expects(:send_message).never

    (limit + 1).times do |index|
      post password_path, params: { contact: user.phone }
      travel AuditEventService::DEDUP_WINDOW + 1.second if index < limit
    end

    assert_equal limit, Event.where(action: 'account_access_instructions_delivery_unavailable', auditable: user).count
    assert_equal 1, Event.where(action: 'account_access_instructions_rate_limited', auditable: user).count
    assert_budget_prefix_present('auth_rate_limit:account_access:user_ip:')
    assert_budget_prefix_absent('account_access:')
  ensure
    travel_back
    Rails.cache = old_cache
  end

  def test_malformed_email_shaped_account_access_does_not_fall_through_to_phone
    sign_out if respond_to?(:sign_out)

    phone = '410-555-0164'
    Current.paper_context = true
    user = nil
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyMalformedAccess',
        phone: phone,
        phone_type: 'text',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password1234', password_confirmation: 'password1234',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '4105550164@' }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_equal user, User.find_by_phone(phone)
  end

  def test_email_shaped_account_access_does_not_fall_through_to_phone
    sign_out if respond_to?(:sign_out)

    phone = '410-555-0165'
    Current.paper_context = true
    user = nil
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyAccess',
        phone: phone,
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password1234', password_confirmation: 'password1234',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '4105550165@example.com' }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_equal user, User.find_by_phone(phone)
  end

  def account_access_confirmation_message(locale: I18n.locale)
    I18n.t(
      'portal_self_service.account_access.confirmation',
      locale: locale,
      support_email: ProgramContact.support_email,
      support_phone: ProgramContact.support_phone_display
    )
  end

  private

  def blank_password_submissions
    ['', ' ' * UserAuthentication::PASSWORD_MIN_LENGTH].map do |password|
      { password: password, password_confirmation: password }
    end << {}
  end

  def create_basic_email_templates
    unless EmailTemplate.exists?(name: 'email_header_text', format: :text)
      EmailTemplate.create!(
        name: 'email_header_text',
        format: :text,
        subject: 'Header Template',
        description: 'Email header template for testing',
        body: 'Maryland Accessible Telecommunications Program'
      )
    end

    return if EmailTemplate.exists?(name: 'email_footer_text', format: :text)

    EmailTemplate.create!(
      name: 'email_footer_text',
      format: :text,
      subject: 'Footer Template',
      description: 'Email footer template for testing',
      body: 'Contact us at support@mat.maryland.gov'
    )
  end

  def set_auth_rate_limit_policy(key, value)
    policy = Policy.find_or_initialize_by(key: key)
    if policy.new_record?
      policy.value = value
      policy.save!
    else
      policy.update_column(:value, value)
    end
  end

  def assert_budget_prefix_present(prefix)
    assert budget_keys.any? { |key| key.start_with?(prefix) }, "Expected budget prefix #{prefix.inspect}"
  end

  def assert_budget_prefix_absent(prefix)
    assert budget_keys.none? { |key| key.start_with?(prefix) }, "Expected no budget prefix #{prefix.inspect}"
  end

  def budget_keys
    AuthRateLimitCounter.pluck(:key)
  end
end
