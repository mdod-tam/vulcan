# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: %i[new create]
  def new
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace('sign_in_form', partial: 'sessions/form')
      end
      format.html { redirect_to(_dashboard_for(current_user)) if current_user }
    end
  end

  def create
    user = User.find_by(email: params[:email])

    if !user&.authenticate(params[:password])
      @errors = { email: "Invalid email or password" }
      return render_form_errors
    end

    return sign_in(user) if !user.second_factor_enabled?

    setup_two_factor_session(user)
    redirect_to_two_factor_verification(user)
  end

  def destroy
    # Clean up any 2FA in progress
    TwoFactorAuth.complete_authentication(session) if two_factor_authentication_initiated?

    # Find and destroy the current session if it exists
    if current_user&.sessions
      session_to_destroy = current_user.sessions.find_by(session_token: cookies.signed[:session_token])
      session_to_destroy&.destroy
    end

    # Always clear the session cookie
    cookies.delete(:session_token)

    # Handle different response formats appropriately
    respond_to do |format|
      format.html { redirect_to sign_in_path, notice: 'Signed out successfully' }
      format.turbo_stream { redirect_to sign_in_path, notice: 'Signed out successfully' }
    end
  end

  private

  def render_form_errors
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace('sign_in_form', partial: 'sessions/form')
      end
      format.html do
        redirect_to sign_in_path(email_hint: params[:email]), alert: 'Invalid email or password'
      end
    end
  end

  def handle_invalid_credentials
    # Add user feedback for failed login attempts if User model supports it
    # user = User.find_by(email: params[:email])
    # user&.track_failed_attempt!(request.remote_ip) if user # Assuming track_failed_attempt! exists
    redirect_to sign_in_path(email_hint: params[:email]), alert: 'Invalid email or password'
  end

  def setup_two_factor_session(user)
    cookies.delete(:session_token) # Ensure no old session interferes
    TwoFactorAuth.clear_challenge(session) # Clear any stale challenge
    TwoFactorAuth.store_temp_user_id(session, user.id)
    TwoFactorAuth.store_return_path(session, session[:return_to])
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
      user.sms_credentials.exists?,
      user.webauthn_credentials.exists?
    ].count(true)
  end

  def redirect_to_single_two_factor_method(user)
    if user.totp_credentials.exists?
      redirect_to verify_method_two_factor_authentication_path(type: 'totp')
    elsif user.sms_credentials.exists?
      redirect_to verify_method_two_factor_authentication_path(type: 'sms')
    elsif user.webauthn_credentials.exists?
      redirect_to verify_method_two_factor_authentication_path(type: 'webauthn')
    end
  end
end
