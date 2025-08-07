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

  before_action :ensure_two_factor_initiated_unless_skipped, except: %i[setup]
  before_action :authenticate_user!, only: %i[setup]
  skip_before_action :authenticate_user!, only: %i[verify verify_method process_verification verification_options setup]

  # GET /two_factor_authentication/setup
  def setup
    @user = find_setup_user
    return redirect_to sign_in_path unless @user

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
    @sms_enabled = @user.sms_credentials.exists?

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
    # Get the method and code from params
    method = params[:method]
    code = params[:code]
    result = false

    # Find the user in the 2FA flow
    @user = find_user_for_two_factor
    unless @user
      redirect_to sign_in_path, alert: 'Session expired. Please sign in again.'
      return
    end

    # Verify based on method type
    if method == 'totp'
      result, = verify_totp_credential(code)
    elsif method == 'sms'
      result, = verify_sms_credential(code, nil)
    end

    if result
      # Call the method from ApplicationController to finalize the session
      complete_two_factor_authentication(@user)
    else
      handle_error_response(
        html_render_action: :verify,
        error_message: TwoFactorAuth::ERROR_MESSAGES[:invalid_code]
      )
    end
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
    @sms_enabled = @user.sms_credentials.exists?
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
          error_message: 'No security keys are registered. Please set up a security key first.'
        )
      end
    when 'totp'
      if @totp_enabled
        render 'verify_totp', layout: 'application'
      else
        handle_error_response(
          html_redirect_path: setup_two_factor_authentication_path,
          error_message: 'No authenticator app is set up. Please set up TOTP authentication first.'
        )
      end
    when 'sms'
      handle_sms_verification
    else
      handle_error_response(
        html_redirect_path: verify_two_factor_authentication_path,
        error_message: 'Invalid verification method'
      )
    end
  end

  # Handle SMS verification specifically
  def handle_sms_verification
    if @user.sms_credentials.exists?
      credential = @user.sms_credentials.first
      send_sms_verification_code_for_user(credential, @user)
      render 'verify_sms', layout: 'application'
    else
      handle_error_response(
        html_redirect_path: verify_two_factor_authentication_path,
        error_message: 'SMS verification not available'
      )
    end
  end

  # POST /two_factor_authentication/verify/:type
  def process_verification
    @type = params[:type]

    verification_params = get_verification_params(@type)

    success, message = verify_credential(@type, verification_params)

    respond_to do |format|
      if success
        handle_successful_verification(format)
      else
        handle_failed_verification(format, message)
      end
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

  # Find user for setup flow (authenticated or in 2FA flow)
  def find_setup_user
    current_user || find_user_for_two_factor
  end

  # Set instance variables for credential availability
  def set_credential_availability
    @has_webauthn = @user.webauthn_credentials.exists?
    @has_totp = @user.totp_credentials.exists?
    @has_sms = @user.sms_credentials.exists?
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
                notice: 'Your account is already secured with two-factor authentication.'
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
        render json: { error: 'Unable to create session' }, status: :unprocessable_content
      end
    end
  end

  # Handle failed verification response
  def handle_failed_verification(format, message)
    status = determine_error_status(message)

    format.html do
      set_verification_context
      template = verification_template_for_type(@type)
      handle_error_response(
        html_render_action: template,
        error_message: message,
        status: status
      )
    end
    format.turbo_stream do
      set_verification_context
      handle_error_response(
        error_message: message,
        status: status
      )
    end
    format.json { render json: { error: message }, status: status }
  end

  def set_verification_context
    @user = find_user_for_two_factor
    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.exists?
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

  # Find the user in the middle of two-factor authentication
  def find_user_for_two_factor
    # Use the standardized session key from the TwoFactorAuth module
    user_id = session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]]
    User.find_by(id: user_id) if user_id
  end

  def ensure_two_factor_initiated_unless_skipped
    return if session[:skip_2fa]

    ensure_two_factor_initiated
  end
end
