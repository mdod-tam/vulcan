# frozen_string_literal: true

class ReauthenticationsController < ApplicationController
  skip_before_action :enforce_required_mfa_enrollment
  before_action :private_response
  before_action :set_return_path
  around_action :with_reauthentication_locale

  def new
    set_factor_choices
  end

  def create
    result = reauthentication_service.call(
      password: params[:password], factor: params[:factor_type],
      context: session[:reauthentication_challenge], code: params[:code], assertion: credential_assertion,
      credential_id: params[:credential_id]
    )
    return render_failure unless result.success?

    reset_session
    cookies.signed[:session_token] = _session_cookie_options(result.session_record.session_token)
    redirect_to @return_to, notice: t('reauthentication.completed'), status: :see_other
  rescue Session::AuthenticationRequired
    clear_session_authentication
    redirect_to sign_in_path, alert: t('alerts.sign_in_required'), status: :see_other
  end

  def webauthn_options
    context = reauthentication_service.prepare(password: params[:password])
    return render_challenge_failure unless context && current_user.webauthn_credentials.exists?

    options = WebAuthn::Credential.options_for_get(
      allow: current_user.webauthn_credentials.pluck(:external_id), user_verification: 'preferred'
    )
    session[:reauthentication_challenge] = context.merge('type' => 'webauthn', 'challenge' => options.challenge)
    render json: options
  rescue Session::AuthenticationRequired
    render_challenge_failure
  end

  def sms_code
    context = reauthentication_service.prepare(password: params[:password])
    credential = current_user.sms_credentials.verified.find_by(id: params[:credential_id])
    return render_challenge_failure unless context && credential

    context = reusable_sms_context(context, credential)
    owner = "reauth:#{context['session_id']}:#{context['nonce']}"
    result = TwilioVerifyService.send_verification(
      credential.phone_number,
      purpose: :reauthentication, owner: owner,
      sms_credential_id: credential.id, locale: current_user.effective_message_locale || I18n.default_locale
    )
    return render_challenge_failure unless result[:success] && result[:verification_sid].present?

    context['expires_at'] = [context['expires_at'], result[:code_expires_at].to_i].min
    session[:reauthentication_challenge] = context.merge(
      'type' => 'sms', 'credential_id' => credential.id,
      'verification_sid' => result[:verification_sid], 'owner' => owner
    )
    render json: { message: t('reauthentication.sms_sent') }
  rescue Session::AuthenticationRequired
    render_challenge_failure
  end

  private

  def with_reauthentication_locale(&)
    I18n.with_locale(public_request_locale_param || current_user.effective_message_locale || I18n.default_locale, &)
  end

  def private_response
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Referrer-Policy'] = 'no-referrer'
  end

  def set_return_path
    @return_to = url_from(params[:return_to]) || edit_profile_path
  end

  def set_factor_choices
    @totp_available = current_user.totp_credentials.exists?
    @webauthn_available = current_user.webauthn_credentials.exists?
    @sms_credentials = current_user.sms_credentials.verified.to_a
    @factor_choices = []
    @factor_choices << [t('reauthentication.totp'), 'totp'] if @totp_available
    @factor_choices << [t('reauthentication.webauthn'), 'webauthn'] if @webauthn_available
    @factor_choices << [t('reauthentication.sms'), 'sms'] if @sms_credentials.any?
    @factor_type = params[:factor_type].presence || default_factor_type
  end

  def default_factor_type
    return 'totp' if @totp_available
    return 'webauthn' if @webauthn_available
    return 'sms' if @sms_credentials.any?

    'password'
  end

  def reauthentication_service
    Users::ReauthenticationService.new(user: current_user, session_record: current_session, token: presented_session_token)
  end

  def reusable_sms_context(context, credential)
    previous = session[:reauthentication_challenge]
    binding_keys = %w[user_id session_id token_digest security_version]
    return context unless previous.is_a?(Hash) && previous['type'] == 'sms' &&
                          previous['credential_id'] == credential.id &&
                          previous.slice(*binding_keys) == context.slice(*binding_keys) &&
                          previous['expires_at'].to_i > Time.current.to_i

    previous
  end

  def credential_assertion
    return if params[:credential].blank?

    value = params.expect(:credential)
    JSON.parse(value) if value.is_a?(String) && value.bytesize < 20_000
  rescue JSON::ParserError
    nil
  end

  def render_failure
    set_factor_choices
    flash.now[:alert] = t('reauthentication.invalid')
    render :new, status: :unprocessable_content
  end

  def render_challenge_failure
    render json: { error: t('reauthentication.invalid') }, status: :unprocessable_content
  end
end
