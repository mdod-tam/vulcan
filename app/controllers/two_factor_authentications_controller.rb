# frozen_string_literal: true

# Handles two-factor authentication verification flow for users.
#
# This controller manages the core 2FA verification process including:
# - Setup and verification method selection
# - Processing verification attempts for WebAuthn, TOTP, and SMS
# - Generating WebAuthn verification options
# - Managing the authentication flow state
#
# Credential management (creation, deletion) is handled by TwoFactorCredentialsController.
class TwoFactorAuthenticationsController < ApplicationController
  include TwoFactorVerification
  include TurboStreamResponseHandling

  around_action :with_public_request_locale, except: :setup

  before_action :ensure_two_factor_initiated_unless_skipped, except: %i[setup resend_sms_verification]
  before_action :authenticate_user!, only: %i[setup]
  skip_before_action :authenticate_user!,
                     only: %i[verify verify_method process_verification verification_options setup select_sms_verification resend_sms_verification]
  skip_before_action :enforce_required_mfa_enrollment

  # GET /two_factor_authentication/setup
  def setup
    @user = find_setup_user
    return redirect_to sign_in_path unless @user

    @mfa_required_for_setup_user = mfa_required_for_role?(@user)
    @setup_dashboard_path = _dashboard_for(@user)

    set_credential_availability
    handle_existing_credentials_redirect if existing_credentials? && !force_setup?
  end

  # GET /two_factor_authentication/verify
  def verify
    # Handle both authenticated users and users in 2FA flow
    @user = current_user || find_user_for_two_factor

    unless @user
      redirect_to sign_in_path
      return
    end

    # Check if user has 2FA enabled
    unless @user.second_factor_enabled?
      redirect_to setup_two_factor_authentication_path
      return
    end

    # Set available methods
    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.verified.exists?

    # If only one method is available, redirect directly to it
    available_methods = [@webauthn_enabled, @totp_enabled, @sms_enabled].count(true)
    return unless available_methods == 1

    if @totp_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'totp')
    elsif @sms_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'sms')
    elsif @webauthn_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'webauthn')
    end

    # If multiple methods available, show choice screen. The view will be rendered automatically
  end

  # POST /two_factor_authentication/verify_code
  def verify_code
    process_verification_attempt(params[:method], params)
  end

  # Unified methods

  # GET /two_factor_authentication/verify/:type
  def verify_method
    @type = params[:type]

    # Ensure authentication flow and find the user
    return unless two_factor_flow_authenticated?

    # Set instance variables needed by the views
    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.verified.exists?
    # Determine if platform authenticator is available (example logic, adjust as needed)
    @platform_key_available = @user.webauthn_credentials.exists?(authenticator_type: 'platform')

    # Render the appropriate verification template based on type
    render_verification_template(@type)
  end

  # Authenticate the two-factor flow
  def two_factor_flow_authenticated?
    unless two_factor_auth_in_progress?
      redirect_to sign_in_path
      return false
    end

    @user = find_user_for_two_factor
    unless @user
      redirect_to sign_in_path
      return false
    end

    true
  end

  # Render the appropriate verification template based on type
  def render_verification_template(type)
    case type
    when 'webauthn'
      if @webauthn_enabled
        render 'verify_webauthn', layout: 'application'
      else
        handle_error_response(
          html_redirect_path: setup_two_factor_authentication_path,
          error_message: t('two_factor_verification.errors.key_unavailable')
        )
      end
    when 'totp'
      if @totp_enabled
        render 'verify_totp', layout: 'application'
      else
        handle_error_response(
          html_redirect_path: setup_two_factor_authentication_path,
          error_message: t('two_factor_verification.errors.totp_unavailable')
        )
      end
    when 'sms'
      handle_sms_verification
    else
      handle_error_response(
        html_redirect_path: verify_two_factor_authentication_path,
        error_message: t('two_factor_verification.errors.invalid_method')
      )
    end
  end

  # Handle SMS verification specifically
  def handle_sms_verification
    if @user.sms_credentials.verified.exists?
      @sms_credential = @user.sms_credentials.verified.first
      @sms_code_sent = active_sms_challenge_for?(@sms_credential)
      render 'verify_sms', layout: 'application'
    else
      handle_error_response(
        html_redirect_path: verify_two_factor_authentication_path,
        error_message: t('two_factor_verification.errors.sms_unavailable')
      )
    end
  end

  # POST /two_factor_authentication/verify/:type
  def process_verification
    process_verification_attempt(params[:type], get_verification_params(params[:type]))
  end

  def process_verification_attempt(type, verification_params)
    @type = type
    success, message = if @type.present?
                         verify_credential(@type, verification_params)
                       else
                         [false, t('two_factor_verification.errors.invalid_type')]
                       end

    respond_to do |format|
      if success
        handle_successful_verification(format)
      else
        handle_failed_verification(format, message)
      end
    end
  end

  # POST /two_factor_authentication/verify/sms/select
  def select_sms_verification
    @user = find_user_for_two_factor
    return redirect_to sign_in_path, status: :see_other unless @user

    credential = resolve_sms_credential_for_resend(@user)
    return redirect_to verify_two_factor_authentication_path, alert: t('two_factor_verification.errors.sms_unavailable'), status: :see_other unless credential

    sms_challenge_result = ensure_sms_challenge_for_user(credential, @user)
    case sms_challenge_result
    when :active
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: t('two_factor_verification.sms.active'),
                  status: :see_other
    when :sent
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: t('two_factor_verification.sms.sent'),
                  status: :see_other
    when :sending
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: t('two_factor_verification.sms.sending'),
                  status: :see_other
    else
      redirect_to verify_two_factor_authentication_path,
                  alert: t('two_factor_verification.sms.send_failed'),
                  status: :see_other
    end
  end

  # POST /two_factor_authentication/verify/sms/resend
  def resend_sms_verification
    @user = find_user_for_two_factor
    return redirect_to sign_in_path unless @user

    credential = resolve_sms_credential_for_resend(@user)
    return handle_error_response(error_message: t('two_factor_verification.errors.sms_unavailable')) unless credential

    sms_challenge_result = resend_sms_challenge_for_user(credential, @user)
    if sms_challenge_result == :waiting
      render_resend_wait(credential, sms_resend_wait_seconds_for(credential))
    elsif sms_challenge_result == :sent
      render_resend_success(credential)
    else
      render_resend_failure(credential)
    end
  end

  # Strong parameters for WebAuthn verification
  # Match the exact camelCase keys sent by the WebAuthnJSON client
  def webauthn_verification_params
    params.expect(
      two_factor_authentication: [:id,
                                  :rawId,
                                  :type,
                                  :authenticatorAttachment,
                                  { response: %i[clientDataJSON authenticatorData signature userHandle],
                                    clientExtensionResults: {} }]
    )
  end

  # Support WebAuthn with JSON endpoint for options
  # GET /two_factor_authentication/verification_options/:type
  def verification_options
    @type = params[:type]

    return unless ensure_two_factor_auth_in_progress
    return respond_with_unsupported_type('verification method') unless @type == 'webauthn'

    handle_webauthn_verification_options
  end

  private

  def default_url_options
    super.merge(locale: public_request_locale_param)
  end

  # Find user for setup flow (authenticated or in 2FA flow)
  def find_setup_user
    current_user || find_user_for_two_factor
  end

  # Set instance variables for credential availability
  def set_credential_availability
    @has_webauthn = @user.webauthn_credentials.exists?
    @has_totp = @user.totp_credentials.exists?
    @has_sms = @user.sms_credentials.verified.exists?
  end

  # Check if user has any existing 2FA credentials
  def existing_credentials?
    @has_webauthn || @has_totp || @has_sms
  end

  # Check if force setup parameter is present
  def force_setup?
    params[:force] == 'true'
  end

  # Handle redirects for users with existing credentials
  def handle_existing_credentials_redirect
    if current_user
      redirect_to_authenticated_user_profile
    else
      redirect_to_verification_method
    end
  end

  # Redirect authenticated user to profile with notice
  def redirect_to_authenticated_user_profile
    redirect_to edit_profile_path,
                notice: t('two_factor_verification.already_secured')
  end

  # Redirect to appropriate verification method based on available credentials
  def redirect_to_verification_method
    verification_type = determine_verification_type
    redirect_to verify_method_two_factor_authentication_path(type: verification_type)
  end

  # Determine which verification type to use based on available credentials
  def determine_verification_type
    return 'totp' if @has_totp
    return 'sms' if @has_sms

    'webauthn' if @has_webauthn
  end

  # Handle WebAuthn verification options generation
  def handle_webauthn_verification_options
    user_for_2fa = find_and_validate_2fa_user
    return unless user_for_2fa

    return if generate_webauthn_verification_options(user_for_2fa)

    respond_with_missing_credentials(:webauthn)
  end

  # Get verification parameters based on type
  def get_verification_params(type)
    if type == 'webauthn'
      webauthn_verification_params.to_h
    else
      params
    end
  end

  # Handle successful verification response
  def handle_successful_verification(format)
    @user = find_user_for_two_factor

    format.html { complete_two_factor_authentication(@user) }
    format.json do
      # For JSON requests, we need to handle the authentication completion differently
      # since complete_two_factor_authentication does a redirect
      stored_location = TwoFactorAuth.get_return_path(session) || session.delete(:return_to)
      TwoFactorAuth.complete_authentication(session)
      session_record = _create_and_set_session_cookie(@user)

      if session_record
        # Clear the challenge only after successful sign-in
        TwoFactorAuth.clear_challenge(session)
        return_to = stored_location || _dashboard_for(@user)
        render json: { status: 'success', redirect_url: return_to }
      else
        render json: { error: t('security_key_verification.feedback.session_failed'), error_code: 'session_failed' },
               status: :unprocessable_content
      end
    end
  end

  # Handle failed verification response
  def handle_failed_verification(format, message)
    if @type == 'webauthn'
      message = t('security_key_verification.feedback.failed')
      status = :unprocessable_content
    else
      status = determine_error_status(message)
    end

    format.html do
      if set_verification_context
        template = verification_template_for_type(@type)
        handle_error_response(
          html_render_action: template,
          error_message: message,
          status: status
        )
      else
        redirect_to sign_in_path, alert: message
      end
    end
    format.turbo_stream do
      if @type == 'sms'
        redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                    alert: message,
                    status: :see_other
      elsif set_verification_context
        handle_error_response(
          error_message: message,
          status: status
        )
      else
        redirect_to sign_in_path, alert: message
      end
    end
    format.json do
      error = { error: message }
      error[:error_code] = 'verification_failed' if @type == 'webauthn'
      render json: error, status: status
    end
  end

  # Returns false (without rendering) when the session no longer resolves to a
  # login-active user, e.g. it was retired by a merge mid-flow. Callers must fail
  # closed to sign-in instead of dereferencing a nil @user.
  def set_verification_context
    @user = find_user_for_two_factor
    return false unless @user

    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.verified.exists?
    return true unless @type == 'sms' && @sms_enabled

    @sms_credential = resolve_sms_credential_for_resend(@user)
    @sms_code_sent = @sms_credential.present? && active_sms_challenge_for?(@sms_credential)
    true
  end

  # Determine appropriate HTTP status code based on error message
  def determine_error_status(message)
    case message
    when /credential not found/i, /not found/i
      :not_found
    else
      :unprocessable_content
    end
  end

  # Get template name for verification type
  def verification_template_for_type(type)
    case type
    when 'webauthn' then 'verify_webauthn'
    when 'sms' then 'verify_sms'
    else 'verify_totp' # safe fallback for totp and unknown types
    end
  end

  # Verify a TOTP code
  def totp_code_valid?(code)
    success, _message = verify_totp_credential(code)
    success
  end

  # Verify an SMS code
  def sms_code_valid?(code)
    success, _message = verify_sms_credential(code, nil)
    success
  end

  # Check if two-factor authentication is in progress
  def two_factor_auth_in_progress?
    # Use the standardized session key from the TwoFactorAuth module
    session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]].present?
  end

  # Find the user in the middle of two-factor authentication. A record retired by a
  # same-person merge (or otherwise not login-active) must never progress through
  # verification, SMS send/resend, or credential updates, so it fails closed here.
  def find_user_for_two_factor
    # Use the standardized session key from the TwoFactorAuth module
    user_id = session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    return nil unless user_id

    user = User.find_by(id: user_id)
    user if user&.public_login_active?
  end

  def ensure_two_factor_initiated_unless_skipped
    return if session[:skip_2fa]

    ensure_two_factor_initiated
  end

  def resolve_sms_credential_for_resend(user)
    challenge_data = retrieve_challenge
    credential_id = challenge_data[:metadata]&.dig(:credential_id)
    return user.sms_credentials.verified.find_by(id: credential_id) if credential_id.present?

    user.sms_credentials.verified.first
  end

  def render_resend_wait(credential, wait_seconds)
    message = sms_resend_wait_message(wait_seconds)
    respond_to do |format|
      format.html { redirect_to resend_sms_redirect_path(credential), alert: message }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          'sms_resend',
          partial: 'shared/sms_resend',
          locals: {
            resend_path: resend_sms_verification_two_factor_authentication_path,
            message: message,
            message_type: :error
          }
        )
      end
    end
  end

  def resend_sms_redirect_path(_credential)
    verify_method_two_factor_authentication_path(type: 'sms')
  end

  def render_resend_success(credential)
    message = t('two_factor_verification.sms.resent')
    respond_to do |format|
      format.html { redirect_to resend_sms_redirect_path(credential), notice: message }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          'sms_resend',
          partial: 'shared/sms_resend',
          locals: {
            resend_path: resend_sms_verification_two_factor_authentication_path,
            message: message,
            message_type: :success
          }
        )
      end
    end
  end

  def render_resend_failure(credential)
    message = t('two_factor_verification.sms.send_failed')
    respond_to do |format|
      format.html { redirect_to resend_sms_redirect_path(credential), alert: message }
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          'sms_resend',
          partial: 'shared/sms_resend',
          locals: {
            resend_path: resend_sms_verification_two_factor_authentication_path,
            message: message,
            message_type: :error
          }
        )
      end
    end
  end
end
