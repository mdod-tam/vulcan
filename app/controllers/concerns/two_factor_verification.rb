# frozen_string_literal: true

# This module handles verification of multiple 2FA credential types:
# - WebAuthn (security keys and biometric authenticators)
# - TOTP (time-based one-time passwords from authenticator apps)
# - SMS (text message verification codes)
#
# The module integrates with the TwoFactorAuth service module for logging
# and session management, ensuring consistent behavior across the application.
module TwoFactorVerification # rubocop:disable Metrics/ModuleLength
  extend ActiveSupport::Concern

  protected

  # Challenge management methods (Now directly using TwoFactorAuth module)
  def store_challenge(type, challenge, metadata = {})
    TwoFactorAuth.store_challenge(session, type, challenge, metadata)
  end

  def retrieve_challenge
    TwoFactorAuth.retrieve_challenge(session)
  end

  def clear_challenge
    TwoFactorAuth.clear_challenge(session)
  end

  # Verification result methods
  def complete_verification(_user_id, _type)
    # Log successful verification (using TwoFactorAuth module)
    # Note: The log_verification_success/failure methods below already call the module
    # TwoFactorAuth.log_verification_success(user_id, type) # Redundant call

    # Complete the authentication process (using TwoFactorAuth module)
    TwoFactorAuth.complete_authentication(session)
  end

  # Updated log calls within verification methods to pass context hash
  def log_verification_success(user_id, type, context = {})
    TwoFactorAuth.log_verification_success(user_id, type, context)
  end

  def log_verification_failure(user_id, type, error, context = {})
    TwoFactorAuth.log_verification_failure(user_id, type, error, context)
  end

  # Unified verification methods that delegate to type-specific handlers
  def verify_credential(type, params)
    case type.to_sym
    when :webauthn
      verify_webauthn_credential(params)
    when :totp
      verify_totp_credential(params[:code])
    when :sms
      verify_sms_credential(params[:code], params[:credential_id])
    else
      [false, 'Invalid credential type']
    end
  end

  def verify_webauthn_credential(params)
    with_verified_user(:webauthn) do |user|
      verify_webauthn_challenge(params, user)
    end
  end

  def verify_totp_credential(code)
    return [false, 'No code provided'] if code.blank?

    with_verified_user(:totp) do |user|
      verify_totp_code(code, user)
    end
  end

  def verify_sms_credential(code, credential_id)
    return [false, 'No code provided'] if code.blank?

    # SMS login verification resolves the credential from 2FA session context
    # This method is used during login when current_user is nil and user data comes from session
    credential_id = resolve_sms_credential_id(credential_id)
    return [false, 'No credential found'] if credential_id.blank?

    credential = find_sms_credential(credential_id)
    return [false, 'Credential not found'] if credential.nil?

    verify_sms_code(code, credential)
  end

  private

  # Base verification method with common user validation
  def with_verified_user(_credential_type)
    user_for_2fa = find_user_for_two_factor
    return [false, 'User session not found'] unless user_for_2fa

    yield(user_for_2fa)
  end

  # WebAuthn specific verification
  def verify_webauthn_challenge(params, user)
    webauthn_credential = WebAuthn::Credential.from_get(params)
    stored_credential = user.webauthn_credentials.find_by(external_id: webauthn_credential.id)
    return [false, 'Credential not found'] unless stored_credential

    perform_webauthn_verification(webauthn_credential, stored_credential, user)
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
  rescue WebAuthn::Error => e
    log_verification_failure(user.id, :webauthn, e.message, credential_id: stored_credential&.id)
    [false, "Verification failed: #{e.message}"]
  end

  # TOTP specific verification
  def verify_totp_code(code, user)
    user.totp_credentials.each do |credential|
      totp = ROTP::TOTP.new(credential.secret)
      next unless totp.verify(code, drift_behind: 30, drift_ahead: 30)

      credential.update(last_used_at: Time.current)
      log_verification_success(user.id, :totp, credential_id: credential.id)
      return [true, 'Verification successful'] # Let the controller handle completion
    end

    log_verification_failure(user.id, :totp, 'Invalid code', credential_ids: user.totp_credentials.pluck(:id))
    [false, TwoFactorAuth::ERROR_MESSAGES[:invalid_code]]
  end

  # SMS specific verification helpers
  def resolve_sms_credential_id(credential_id)
    # SMS login flow stores credential_id in challenge metadata during code generation
    # When no challenge data exists (e.g., in tests), fall back to the user's first SMS credential
    return credential_id if credential_id.present?

    challenge_data = retrieve_challenge
    credential_id_from_challenge = challenge_data[:metadata]&.dig(:credential_id)
    return credential_id_from_challenge if credential_id_from_challenge.present?

    # If no challenge data (e.g., in tests), use the user's first SMS credential
    user_for_2fa = find_user_for_two_factor
    sms_credentials = user_for_2fa&.sms_credentials
    sms_credentials&.first&.id
  end

  def find_sms_credential(credential_id)
    user_for_2fa = find_user_for_two_factor
    return nil unless user_for_2fa

    user_for_2fa.sms_credentials.find_by(id: credential_id)
  end

  def verify_sms_code(code, credential)
    # Use Twilio Verify API to check the code
    result = TwilioVerifyService.check_verification(credential.phone_number, code)
    user_for_2fa = find_user_for_two_factor

    if result[:success] && result[:status] == 'approved'
      clear_challenge
      log_verification_success(user_for_2fa.id, :sms, credential_id: credential.id)
      [true, 'Verification successful'] # Let the controller handle completion
    elsif result[:success]
      error_msg = result[:error] || 'Invalid code'
      log_verification_failure(user_for_2fa.id, :sms, error_msg, credential_id: credential.id)
      [false, sms_verification_error_message(result[:status])]
    else
      error_msg = result[:error] || 'Verification service unavailable'
      log_verification_failure(user_for_2fa.id, :sms, error_msg, credential_id: credential.id)
      [false, TwoFactorAuth::ERROR_MESSAGES[:verification_service_unavailable]]
    end
  end

  def sms_verification_error_message(status)
    case status
    when 'expired'
      TwoFactorAuth::ERROR_MESSAGES[:expired_code]
    when 'max_attempts_reached'
      TwoFactorAuth::ERROR_MESSAGES[:max_attempts_reached]
    else
      TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
    end
  end

  protected

  # Error handling methods
  def handle_verification_error(error, type, format = :html)
    error_message = get_friendly_error_message(error, type)
    log_verification_failure(current_user.id, type, error_message)

    if format == :json || request.xhr?
      render json: { error: error_message, details: error.message }, status: :unprocessable_content
    else
      flash.now[:alert] = error_message
      render :new
    end
  end

  def get_friendly_error_message(error, type)
    case type
    when :webauthn
      case error.message
      when /challenge/i
        TwoFactorAuth::ERROR_MESSAGES[:webauthn_challenge_mismatch]
      when /already registered/i
        'This security key is already registered with your account.'
      when /user verification/i
        'Your device rejected the verification. Please ensure your fingerprint or PIN is set up correctly.'
      else
        "Verification failed: #{error.message}"
      end
    else
      TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
    end
  end

  # Shared helper methods for credential management

  # Helper method to validate phone numbers
  def valid_phone_number?(phone)
    # Basic validation (could use a gem like phonelib for better validation)
    phone.present? && phone.gsub(/\D/, '').length >= 10
  end

  # Validates TOTP secret to prevent XSS - uses ROTP's own validation
  def validate_base32_secret(secret)
    return nil if secret.blank?

    # Ensure secret is a string and contains only valid Base32 characters
    secret = secret.to_s.strip
    return nil unless secret.match?(/\A[A-Z2-7]+\z/)

    # Use ROTP to validate the secret format
    ROTP::Base32.decode(secret)
    secret
  rescue ArgumentError, ROTP::Base32::Base32Error
    nil
  end

  # Get a validated TOTP secret, never using params directly
  def get_validated_totp_secret(param_secret)
    # Use the secret from params if provided (for redirects after failed verification),
    # otherwise generate a new one. Always validate secret to prevent XSS.
    if param_secret.present?
      validated_secret = validate_base32_secret(param_secret)
      validated_secret || ROTP::Base32.random # Fallback if validation fails
    else
      ROTP::Base32.random
    end
  end

  # Generate QR code with validated secret only
  def generate_totp_qr_code
    # Only use the validated @secret instance variable
    @totp_uri = ROTP::TOTP.new(@secret, issuer: 'MatVulcan').provisioning_uri(current_user.email)
    @qr_code = RQRCode::QRCode.new(@totp_uri).as_svg(
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 4,
      standalone: true,
      use_path: true
    )
  end

  # Send an SMS verification code using Twilio Verify API
  def send_sms_verification_code(credential = nil)
    # If no credential is provided, use current user's first SMS credential
    credential ||= current_user&.sms_credentials&.first
    return false unless credential

    # Use Twilio Verify API to send verification code
    result = TwilioVerifyService.send_verification(credential.phone_number)

    if result[:success]
      # Update credential with timestamp
      credential.update!(
        last_sent_at: Time.current,
        code_expires_at: 10.minutes.from_now
      )

      # Store challenge data with verification SID
      store_challenge(
        :sms,
        result[:verification_sid],
        { credential_id: credential.id, phone_number: credential.phone_number }
      )

      user_id = credential.user_id
      Rails.logger.info("[SMS] Sent verification code to user #{user_id} via Twilio Verify")
      true
    else
      Rails.logger.error("[SMS] Failed to send verification: #{result[:error]}")
      flash.now[:alert] = 'Could not send verification code'
      false
    end
  rescue StandardError => e
    Rails.logger.error("[SMS] Error: #{e.message}")
    Rails.logger.error("[SMS] Error backtrace: #{e.backtrace.first(5).join("\n")}")
    flash.now[:alert] = 'Could not send verification code'
    false
  end
  # rubocop:enable Metrics/AbcSize

  # Send SMS verification code for a specific user (used in 2FA flow)
  def send_sms_verification_code_for_user(credential, user)
    return false unless credential && user

    # Use Twilio Verify API to send verification code
    result = TwilioVerifyService.send_verification(credential.phone_number)

    if result[:success]
      # Update credential with timestamp
      credential.update!(
        last_sent_at: Time.current,
        code_expires_at: 10.minutes.from_now
      )

      # Store challenge data with verification SID
      store_challenge(
        :sms,
        result[:verification_sid],
        { credential_id: credential.id, phone_number: credential.phone_number }
      )

      Rails.logger.info("[SMS] Sent verification code to user #{user.id} via Twilio Verify")
      true
    else
      Rails.logger.error("[SMS] Failed to send verification: #{result[:error]}")
      flash.now[:alert] = 'Could not send verification code'
      false
    end
  rescue StandardError => e
    Rails.logger.error("[SMS] Error: #{e.message}")
    flash.now[:alert] = 'Could not send verification code'
    false
  end

  # WebAuthn credential creation options for platform authenticators (biometrics)
  def build_platform_create_options
    WebAuthn::Credential.options_for_create(
      user: {
        id: current_user.webauthn_id,
        name: current_user.email
      },
      exclude: current_user.webauthn_credentials.pluck(:external_id),
      authenticator_selection: {
        authenticator_attachment: 'platform',
        resident_key: 'preferred',
        user_verification: 'preferred'
      }
    )
  end

  # WebAuthn credential creation options for cross-platform authenticators (security keys)
  def build_cross_platform_create_options
    WebAuthn::Credential.options_for_create(
      user: {
        id: current_user.webauthn_id,
        name: current_user.email
      },
      exclude: current_user.webauthn_credentials.pluck(:external_id)
    )
  end

  # Shared response handling patterns
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

  # WebAuthn options generation with common response handling
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

  # Shared authentication flow validation
  def ensure_two_factor_auth_in_progress # rubocop:disable Naming/PredicateMethod
    return true if two_factor_auth_in_progress?

    respond_with_authentication_required
    false
  end

  # Shared user finding with validation
  def find_and_validate_2fa_user
    user = find_user_for_two_factor
    return user if user

    respond_with_authentication_required
    nil
  end
end
