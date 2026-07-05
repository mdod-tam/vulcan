# frozen_string_literal: true

# Base controller that all other controllers inherit from
# Includes authentication, CSRF protection, and password change enforcement
class ApplicationController < ActionController::Base
  include Authentication
  include Pagy::Frontend

  protect_from_forgery with: :exception

  # Extended flash types for accessible, semantic notifications
  add_flash_types :info, :error, :success, :warning

  # Include our helpers
  helper PasswordFieldHelper
  helper EmailStatusHelper
  helper_method :dashboard_path_for_current_user, :mfa_required_for_current_user?,
                :public_form_locale_param, :public_request_locale_param

  before_action :check_password_change_required
  before_action :enforce_required_mfa_enrollment

  def default_url_options
    if Rails.env.production?
      # Fail fast if APPLICATION_HOST is not configured in production
      { host: ENV.fetch('APPLICATION_HOST'), protocol: 'https' }
    else
      {}
    end
  end

  private

  def check_password_change_required
    return unless current_user&.force_password_change?

    # Skip the check on the password edit page and during password update
    return if controller_name == 'passwords' && %w[edit update].include?(action_name)

    # Store the current path to return after password change
    store_location if request.get? && !request.xhr?

    # Redirect to password change form with notice
    redirect_to edit_password_path,
                notice: t('controllers.application.check_password_change_required.password_security_change')
  end

  def enforce_required_mfa_enrollment
    return if Rails.env.test? && session[:skip_2fa]
    return unless mfa_required_for_current_user?
    return if current_user.second_factor_enabled?

    redirect_to setup_two_factor_authentication_path,
                alert: 'Please set up two-factor authentication to continue.'
  end

  def mfa_required_for_current_user?
    current_user.present? && mfa_required_for_role?(current_user)
  end

  def dashboard_path_for_current_user
    return sign_in_path unless current_user

    _dashboard_for(current_user)
  end

  def mfa_required_for_role?(user)
    user.admin? || user.evaluator? || user.trainer? || user.vendor?
  end

  # Public neutral auth flows should use only request-selected locale, not a
  # matched account's locale, so translations do not become an existence signal.
  def with_public_request_locale(&)
    I18n.with_locale(public_request_locale, &)
  end

  def public_request_locale
    public_form_locale_param || I18n.default_locale
  end

  def public_request_locale_param
    public_locale_from(params[:locale])
  end

  def public_form_locale_param
    public_request_locale_param || public_locale_from(params.dig(:user, :locale))
  end

  def public_locale_from(value)
    locale = value.to_s
    return if locale.blank?

    locale if I18n.available_locales.map(&:to_s).include?(locale)
  end

  def canonical_public_url_options
    CanonicalPublicUrlOptions.call
  end

  def after_sign_in_path_for(user)
    return _dashboard_for(user) if Rails.env.test? && session[:skip_2fa]
    return setup_two_factor_authentication_path if mfa_required_for_role?(user) && !user.second_factor_enabled?

    _dashboard_for(user)
  end

  # Standard flash helper methods
  # rubocop:disable Rails/ActionControllerFlashBeforeRender
  def flash_success(message)
    flash[:success] = message
  end

  def flash_error(message)
    flash[:error] = message
  end

  def flash_warning(message)
    flash[:warning] = message
  end

  def flash_info(message)
    flash[:info] = message
  end
  # rubocop:enable Rails/ActionControllerFlashBeforeRender

  # Immediate (render-safe) flash helpers
  def flash_success_now(message)
    flash.now[:success] = message
  end

  def flash_error_now(message)
    flash.now[:error] = message
  end

  def flash_warning_now(message)
    flash.now[:warning] = message
  end

  def flash_info_now(message)
    flash.now[:info] = message
  end

  # Creates a session, sets the cookie, tracks sign-in, and redirects.
  # To be called after successful authentication (password or 2FA).
  def sign_in(user)
    session_record = _create_and_set_session_cookie(user)
    if session_record
      redirect_to after_sign_in_path_for(user), notice: t('controllers.application.sign_in.signin_pass')
    else
      redirect_to sign_in_path, alert: t('alerts.session_fail')
    end
  end

  # Creates the Session record and sets the secure cookie.
  # Returns the session record on success, nil on failure.
  def _create_and_set_session_cookie(user)
    session_record = user.sessions.new(
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    )
    return unless session_record.save

    cookies.signed[:session_token] = _session_cookie_options(session_record.session_token)
    user.track_sign_in!(request.remote_ip) # Assuming this method exists on User model
    session_record
  end

  # Generates options for the session cookie.
  def _session_cookie_options(token)
    {
      value: token,
      httponly: true,
      secure: Rails.env.production?
      # Consider adding SameSite attribute for enhanced security:
      # same_site: :lax # or :strict depending on your needs
    }
  end

  # Determines the appropriate dashboard path based on user type.
  def _dashboard_for(user)
    case user.type
    when 'Users::Administrator' then admin_dashboard_path
    when 'Users::Constituent' then constituent_portal_dashboard_path
    when 'Users::Evaluator' then evaluators_dashboard_path
    when 'Users::Trainer' then trainers_dashboard_path
    when 'Users::Vendor' then vendor_portal_dashboard_path
    else edit_profile_path
    end
  end

  # Completes the 2FA authentication and redirects appropriately
  def complete_two_factor_authentication(user)
    # Get the return path BEFORE clearing the 2FA session data
    stored_location = TwoFactorAuth.get_return_path(session) || session.delete(:return_to)

    # Complete the 2FA authentication process (but preserve challenge until after sign-in)
    TwoFactorAuth.complete_authentication(session)

    # Create the session and redirect
    session_record = _create_and_set_session_cookie(user)

    if session_record
      # Clear the challenge only after successful sign-in
      TwoFactorAuth.clear_challenge(session)
      # Redirect to stored location or appropriate dashboard
      redirect_to stored_location || _dashboard_for(user), notice: t('controllers.application.complete_two_factor_authentication.signin_pass_2fa')
    else
      redirect_to sign_in_path, alert: t('alerts.session_fail')
    end
  end

  # Checks if a 2FA authentication process has been initiated
  def two_factor_authentication_initiated?
    TwoFactorAuth.get_temp_user_id(session).present?
  end

  # Finds the user for whom 2FA is in progress
  def find_user_for_two_factor
    user_id = TwoFactorAuth.get_temp_user_id(session)
    user_id ? User.find(user_id) : nil
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Ensures a 2FA flow has been initiated
  def ensure_two_factor_initiated
    redirect_to sign_in_path unless two_factor_authentication_initiated?
  end

  # Ensures a user is not fully authenticated (used for 2FA step)
  def ensure_user_not_authenticated
    redirect_to root_path if current_user # current_user checks the final session_token cookie
  end

  # Legacy method name for backward compatibility
  alias ensure_login_initiated ensure_two_factor_initiated
end
