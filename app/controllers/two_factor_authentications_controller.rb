# frozen_string_literal: true

# TwoFactorCredentialsController owns credential creation and deletion.
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
    @user = current_user || find_user_for_two_factor

    unless @user
      redirect_to sign_in_path
      return
    end

    unless @user.second_factor_enabled?
      redirect_to setup_two_factor_authentication_path
      return
    end

    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.verified.exists?

    available_methods = [@webauthn_enabled, @totp_enabled, @sms_enabled].count(true)
    return unless available_methods == 1

    if @totp_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'totp')
    elsif @sms_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'sms')
    elsif @webauthn_enabled
      redirect_to verify_method_two_factor_authentication_path(type: 'webauthn')
    end
  end

  # POST /two_factor_authentication/verify_code
  def verify_code
    process_verification_attempt(params[:method], params)
  end

  # GET /two_factor_authentication/verify/:type
  def verify_method
    @type = params[:type]

    return unless two_factor_flow_authenticated?

    @webauthn_enabled = @user.webauthn_credentials.exists?
    @totp_enabled = @user.totp_credentials.exists?
    @sms_enabled = @user.sms_credentials.verified.exists?
    @platform_key_available = @user.webauthn_credentials.exists?(authenticator_type: 'platform')

    render_verification_template(@type)
  end

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
    when :suppressed, :configuration_error
      redirect_to verify_two_factor_authentication_path,
                  alert: t("outbound_delivery.sms_#{sms_challenge_result}"), status: :see_other
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
      render_resend_failure(credential, sms_challenge_result)
    end
  end

  # Preserve the camelCase keys from the WebAuthnJSON client.
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

  def find_setup_user
    current_user || find_user_for_two_factor
  end

  def set_credential_availability
    @has_webauthn = @user.webauthn_credentials.exists?
    @has_totp = @user.totp_credentials.exists?
    @has_sms = @user.sms_credentials.verified.exists?
  end

  def existing_credentials?
    @has_webauthn || @has_totp || @has_sms
  end

  def force_setup?
    params[:force] == 'true'
  end

  def handle_existing_credentials_redirect
    if current_user
      redirect_to_authenticated_user_profile
    else
      redirect_to_verification_method
    end
  end

  def redirect_to_authenticated_user_profile
    redirect_to edit_profile_path,
                notice: t('two_factor_verification.already_secured')
  end

  def redirect_to_verification_method
    verification_type = determine_verification_type
    redirect_to verify_method_two_factor_authentication_path(type: verification_type)
  end

  def determine_verification_type
    return 'totp' if @has_totp
    return 'sms' if @has_sms

    'webauthn' if @has_webauthn
  end

  def handle_webauthn_verification_options
    user_for_2fa = find_and_validate_2fa_user
    return unless user_for_2fa

    return if generate_webauthn_verification_options(user_for_2fa)

    respond_with_missing_credentials(:webauthn)
  end

  def get_verification_params(type)
    if type == 'webauthn'
      webauthn_verification_params.to_h
    else
      params
    end
  end

  def handle_successful_verification(format)
    @user = find_user_for_two_factor

    format.html { complete_two_factor_authentication(@user) }
    format.json do
      # The JSON response supplies a redirect URL instead of an HTTP redirect.
      stored_location = TwoFactorAuth.get_return_path(session) || session.delete(:return_to)
      TwoFactorAuth.complete_authentication(session)
      session_record = _create_and_set_session_cookie(@user)

      if session_record
        # Clear the challenge only after session creation succeeds.
        TwoFactorAuth.clear_challenge(session)
        return_to = stored_location || _dashboard_for(@user)
        render json: { status: 'success', redirect_url: return_to }
      else
        render json: { error: t('security_key_verification.feedback.session_failed'), error_code: 'session_failed' },
               status: :unprocessable_content
      end
    end
  end

  def handle_failed_verification(format, message)
    error_code = message if message.is_a?(Symbol)
    message = case message
              when :verification_failed then t('security_key_verification.feedback.failed')
              when :user_session then t('two_factor_verification.errors.user_session')
              else message
              end

    format.html do
      if set_verification_context
        template = verification_template_for_type(@type)
        handle_error_response(
          html_render_action: template,
          error_message: message,
          status: :unprocessable_content
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
          status: :unprocessable_content
        )
      else
        redirect_to sign_in_path, alert: message
      end
    end
    format.json do
      error = { error: message }
      error[:error_code] = error_code if error_code
      render json: error, status: :unprocessable_content
    end
  end

  # Return false without a response if the session cannot resolve a login-active user.
  # Callers must redirect to sign-in if a merge retires the account mid-flow.
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

  def verification_template_for_type(type)
    case type
    when 'webauthn' then 'verify_webauthn'
    when 'sms' then 'verify_sms'
    else 'verify_totp' # Unknown types also use the TOTP template.
    end
  end

  def totp_code_valid?(code)
    success, _message = verify_totp_credential(code)
    success
  end

  def sms_code_valid?(code)
    success, _message = verify_sms_credential(code, nil)
    success
  end

  def two_factor_auth_in_progress?
    session[TwoFactorAuth::SESSION_KEYS[:temp_user_id]].present?
  end

  # Reject accounts retired by a merge or otherwise not login-active.
  # Verification and SMS send/resend use this access boundary.
  def find_user_for_two_factor
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

  def render_resend_failure(credential, outcome = nil)
    message = if %i[suppressed configuration_error].include?(outcome)
                t("outbound_delivery.sms_#{outcome}")
              else
                t('two_factor_verification.sms.send_failed')
              end
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
