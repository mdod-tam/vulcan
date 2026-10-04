# frozen_string_literal: true

# Verifies WebAuthn, TOTP, and SMS second factors. TwoFactorAuth
# (config/initializers/two_factor_auth.rb) owns the session keys and logs.
module TwoFactorVerification
  extend ActiveSupport::Concern

  protected

  def store_challenge(type, challenge, metadata = {})
    TwoFactorAuth.store_challenge(session, type, challenge, metadata)
  end

  def retrieve_challenge
    TwoFactorAuth.retrieve_challenge(session)
  end

  def clear_challenge
    TwoFactorAuth.clear_challenge(session)
  end

  def complete_verification(_user_id, _type)
    TwoFactorAuth.complete_authentication(session)
  end

  def log_verification_success(user_id, type, context = {})
    TwoFactorAuth.log_verification_success(user_id, type, context)
  end

  def log_verification_failure(user_id, type, error, context = {})
    TwoFactorAuth.log_verification_failure(user_id, type, error, context)
  end

  # Returns [success, message_or_error_code]. On failure, handle_failed_verification
  # translates :user_session and :verification_failed or uses the localized message.
  def verify_credential(type, params)
    case type.to_sym
    when :webauthn
      verify_webauthn_credential(params)
    when :totp
      verify_totp_credential(params[:code])
    when :sms
      verify_sms_credential(params[:code], params[:credential_id])
    else
      [false, t('two_factor_verification.errors.invalid_type')]
    end
  end

  def verify_webauthn_credential(params)
    with_verified_user(:webauthn) do |user|
      verify_webauthn_challenge(params, user)
    end
  end

  def verify_totp_credential(code)
    return [false, t('two_factor_verification.errors.no_code')] if code.blank?

    with_verified_user(:totp) do |user|
      verify_totp_code(code, user)
    end
  end

  def verify_sms_credential(code, credential_id)
    return [false, t('two_factor_verification.errors.no_code')] if code.blank?

    user = find_user_for_two_factor
    return [false, :user_session] unless user

    credential = sms_credential_from_active_challenge(user, credential_id)
    return [false, t('two_factor_verification.errors.expired_code')] unless credential

    verify_sms_code(code, credential)
  end

  private

  def with_verified_user(_credential_type)
    user_for_2fa = find_user_for_two_factor
    return [false, :user_session] unless user_for_2fa

    yield(user_for_2fa)
  end

  def verify_webauthn_challenge(params, user)
    webauthn_credential = WebAuthn::Credential.from_get(params)
    stored_credential = user.webauthn_credentials.find_by(external_id: webauthn_credential.id)
    unless stored_credential
      log_verification_failure(user.id, :webauthn, 'Credential not found')
      return [false, :verification_failed]
    end

    perform_webauthn_verification(webauthn_credential, stored_credential, user)
  rescue WebAuthn::Error, OpenSSL::PKey::PKeyError => e
    log_verification_failure(user.id, :webauthn, e.class.name, credential_id: stored_credential&.id)
    [false, :verification_failed]
  end

  def perform_webauthn_verification(webauthn_credential, stored_credential, user)
    challenge = retrieve_challenge[:challenge]
    webauthn_credential.verify(
      challenge,
      public_key: stored_credential.public_key,
      sign_count: stored_credential.sign_count
    )

    stored_credential.update!(sign_count: webauthn_credential.sign_count)
    log_verification_success(user.id, :webauthn, credential_id: stored_credential.id)
    [true, 'Verification successful']
  end

  def verify_totp_code(code, user)
    user.totp_credentials.each do |credential|
      totp = ROTP::TOTP.new(credential.secret)
      next unless totp.verify(code, drift_behind: 30, drift_ahead: 30)

      credential.update(last_used_at: Time.current)
      log_verification_success(user.id, :totp, credential_id: credential.id)
      return [true, 'Verification successful'] # The controller completes sign-in.
    end

    log_verification_failure(user.id, :totp, 'Invalid code', credential_ids: user.totp_credentials.pluck(:id))
    [false, t('two_factor_verification.errors.invalid_code')]
  end

  def sms_credential_from_active_challenge(user, submitted_credential_id)
    challenge_data = retrieve_challenge
    metadata = (challenge_data[:metadata] || {}).with_indifferent_access
    return unless challenge_data[:type].to_s == 'sms'
    return if submitted_credential_id.present? && metadata[:credential_id].to_s != submitted_credential_id.to_s

    credential = user.sms_credentials.verified.find_by(id: metadata[:credential_id])
    return unless credential
    return unless sms_login_challenge(credential).active?

    credential
  end

  def verify_sms_code(code, credential)
    challenge = sms_login_challenge(credential)
    result = challenge.check(code)
    return [false, t('two_factor_verification.errors.expired_code')] unless result

    user_for_2fa = find_user_for_two_factor

    if result[:success] && result[:status] == 'approved'
      challenge.clear!
      log_verification_success(user_for_2fa.id, :sms, credential_id: credential.id)
      [true, 'Verification successful'] # The controller completes sign-in.
    elsif result[:success]
      challenge.clear! if challenge.terminal_status?(result[:status])
      error_msg = result[:error] || 'Invalid code'
      log_verification_failure(user_for_2fa.id, :sms, error_msg, credential_id: credential.id)
      [false, sms_verification_error_message(result[:status])]
    else
      error_msg = result[:error] || 'Verification service unavailable'
      log_verification_failure(user_for_2fa.id, :sms, error_msg, credential_id: credential.id)
      [false, t('two_factor_verification.errors.verification_service_unavailable')]
    end
  end

  def sms_verification_error_message(status)
    case status
    when 'expired', 'not_found'
      t('two_factor_verification.errors.expired_code')
    when 'max_attempts_reached'
      t('two_factor_verification.errors.max_attempts_reached')
    else
      t('two_factor_verification.errors.invalid_code')
    end
  end

  protected

  def valid_phone_number?(phone)
    # Only counts digits. It does not validate the number format.
    phone.present? && phone.gsub(/\D/, '').length >= 10
  end

  # Returns nil unless the secret is Base32. The secret goes into HTML and URLs, so
  # the character limit prevents XSS.
  def validate_base32_secret(secret)
    return nil if secret.blank?

    secret = secret.to_s.strip
    return nil unless secret.match?(/\A[A-Z2-7]+\z/)

    ROTP::Base32.decode(secret)
    secret
  rescue ArgumentError, ROTP::Base32::Base32Error
    nil
  end

  # Returns the params secret if it is valid Base32. The failed setup redirect sends one.
  # Otherwise returns a new random secret.
  def get_validated_totp_secret(param_secret)
    if param_secret.present?
      validated_secret = validate_base32_secret(param_secret)
      validated_secret || ROTP::Base32.random
    else
      ROTP::Base32.random
    end
  end

  # Callers must set @secret to a validated secret first.
  def generate_totp_qr_code
    @totp_uri = ROTP::TOTP.new(@secret, issuer: 'MatVulcan').provisioning_uri(current_user.mfa_account_name)
    @qr_code = RQRCode::QRCode.new(@totp_uri).as_svg(
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 4,
      standalone: true,
      use_path: true
    )
  end

  def active_sms_challenge_for?(credential)
    sms_login_challenge(credential).active?
  end

  def ensure_sms_challenge_for_user(credential, user)
    sms_login_challenge(credential).ensure_for!(user)
  end

  def resend_sms_challenge_for_user(credential, user)
    sms_login_challenge(credential).resend_for!(user)
  end

  def sms_resend_wait_seconds_for(credential)
    sms_login_challenge(credential).resend_wait_seconds
  end

  def sms_resend_wait_message(wait_seconds)
    t('two_factor_verification.sms.wait', seconds: wait_seconds)
  end

  def sms_login_challenge(credential)
    TwoFactor::SmsLoginChallenge.new(session: session, credential: credential)
  end

  # Platform authenticators (biometrics).
  def build_platform_create_options
    WebAuthn::Credential.options_for_create(
      user: {
        id: current_user.webauthn_id,
        name: current_user.mfa_account_name
      },
      exclude: current_user.webauthn_credentials.pluck(:external_id),
      authenticator_selection: {
        authenticator_attachment: 'platform',
        resident_key: 'preferred',
        user_verification: 'preferred'
      }
    )
  end

  # Cross-platform authenticators (security keys).
  def build_cross_platform_create_options
    WebAuthn::Credential.options_for_create(
      user: {
        id: current_user.webauthn_id,
        name: current_user.mfa_account_name
      },
      exclude: current_user.webauthn_credentials.pluck(:external_id)
    )
  end

  def respond_with_authentication_required
    respond_to do |format|
      format.html { redirect_to sign_in_path }
      format.json { render json: { error: 'Authentication required' }, status: :unauthorized }
      format.any { redirect_to sign_in_path }
    end
  end

  def respond_with_unsupported_type(type_name = 'credential type')
    respond_to do |format|
      format.json { render json: { error: "Unsupported #{type_name}" }, status: :bad_request }
      format.html { redirect_to sign_in_path, alert: "Invalid #{type_name}." }
    end
  end

  def respond_with_missing_credentials(credential_type)
    error_messages = {
      webauthn: 'No security keys are registered for this account',
      sms: 'SMS verification not available',
      totp: 'No authenticator app is set up'
    }

    error_message = error_messages[credential_type.to_sym] || 'No credentials available'

    respond_to do |format|
      format.json { render json: { error: error_message }, status: :not_found }
      format.html { redirect_to sign_in_path, alert: "#{error_message.gsub('for this account', 'for your account')}." }
    end
  end

  # Returns false and renders nothing if the user has no WebAuthn credentials.
  def generate_webauthn_verification_options(user)
    return false unless user&.webauthn_credentials&.any?

    get_options = WebAuthn::Credential.options_for_get(
      allow: user.webauthn_credentials.pluck(:external_id)
    )
    store_challenge(:webauthn, get_options.challenge)

    respond_to do |format|
      format.json { render json: get_options }
      format.html { handle_html_webauthn_options_request(get_options) }
    end
    true
  end
  # rubocop:enable Naming/PredicateMethod

  def handle_html_webauthn_options_request(get_options)
    if request.xhr?
      render json: get_options
    else
      redirect_to verify_method_two_factor_authentication_path(type: 'webauthn')
    end
  end

  def ensure_two_factor_auth_in_progress # rubocop:disable Naming/PredicateMethod
    return true if two_factor_auth_in_progress?

    respond_with_authentication_required
    false
  end

  def find_and_validate_2fa_user
    user = find_user_for_two_factor
    return user if user

    respond_with_authentication_required
    nil
  end
end
