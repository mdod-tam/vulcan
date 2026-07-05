# frozen_string_literal: true

class SessionsController < ApplicationController
  include TwoFactorVerification

  skip_before_action :authenticate_user!, only: %i[new create]
  skip_before_action :enforce_required_mfa_enrollment
  around_action :with_public_request_locale, only: %i[new create]

  def new
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace('sign_in_form', partial: 'sessions/form')
      end
      format.html { redirect_to(_dashboard_for(current_user)) if current_user }
    end
  end

  def create
    user = User.find_by_login_identifier(login_contact_param)

    if user&.account_locked?
      @errors = { contact: invalid_credentials_message }
      return render_form_errors
    end

    unless user&.authenticate(params[:password])
      user&.record_failed_login!
      @errors = { contact: invalid_credentials_message }
      return render_form_errors
    end

    return sign_in(user) unless user.second_factor_enabled?

    setup_two_factor_session(user)
    redirect_to_two_factor_verification(user)
  end

  def destroy
    TwoFactorAuth.abort_authentication(session)

    if current_user&.sessions
      session_to_destroy = current_user.sessions.find_by(session_token: cookies.signed[:session_token])
      session_to_destroy&.destroy
    end

    cookies.delete(:session_token)

    respond_to do |format|
      format.html { redirect_to sign_in_path, notice: 'Signed out successfully' }
      format.turbo_stream { redirect_to sign_in_path, notice: 'Signed out successfully' }
    end
  end

  private

  def login_contact_param
    params[:contact].presence || params[:email].presence
  end

  def render_form_errors
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace('sign_in_form', partial: 'sessions/form')
      end
      format.html do
        redirect_to sign_in_path(locale: public_request_locale_param), alert: invalid_credentials_message
      end
    end
  end

  def invalid_credentials_message
    t('controllers.sessions.invalid_credentials')
  end

  def setup_two_factor_session(user)
    cookies.delete(:session_token)
    TwoFactorAuth.clear_challenge(session)
    TwoFactorAuth.store_temp_user_id(session, user.id)
    return_path = session[:return_to]
    return_path = nil if return_path&.include?('sign_in') || return_path == '/'
    TwoFactorAuth.store_return_path(session, return_path)
  end

  def redirect_to_two_factor_verification(user)
    available_methods = count_available_two_factor_methods(user)

    case available_methods
    when 0
      redirect_to setup_two_factor_authentication_path
    when 1
      redirect_to_single_two_factor_method(user)
    else
      redirect_to verify_two_factor_authentication_path
    end
  end

  def count_available_two_factor_methods(user)
    [
      user.totp_credentials.exists?,
      user.sms_credentials.verified.exists?,
      user.webauthn_credentials.exists?
    ].count(true)
  end

  def redirect_to_single_two_factor_method(user)
    if user.totp_credentials.exists?
      redirect_to verify_method_two_factor_authentication_path(type: 'totp')
    elsif user.sms_credentials.verified.exists?
      redirect_to_sms_verification_or_sign_in(user)
    elsif user.webauthn_credentials.exists?
      redirect_to verify_method_two_factor_authentication_path(type: 'webauthn')
    end
  end

  def redirect_to_sms_verification_or_sign_in(user)
    sms_challenge_result = ensure_sms_challenge_for_user(user.sms_credentials.verified.first, user)

    case sms_challenge_result
    when :active
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: 'Enter the verification code we sent.'
    when :sent
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: 'A verification code has been sent.'
    when :sending
      redirect_to verify_method_two_factor_authentication_path(type: 'sms'),
                  notice: TwoFactor::SmsLoginChallenge::DUPLICATE_SEND_MESSAGE
    else
      TwoFactorAuth.abort_authentication(session)
      redirect_to sign_in_path,
                  alert: 'Could not send verification code. Please try again.'
    end
  end
end
