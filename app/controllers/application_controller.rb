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
  #
  # +submitted_login_identifier+ and +submitted_password+ are the exact credentials the
  # requester submitted (password sign-in only; 2FA completion omits both). They are passed
  # through only for this immediate locked recheck and are never stored in session/cookies.
  def sign_in(user, submitted_login_identifier: nil, submitted_password: nil)
    session_record = _create_and_set_session_cookie(
      user,
      submitted_login_identifier: submitted_login_identifier,
      submitted_password: submitted_password
    )
    if session_record
      redirect_to after_sign_in_path_for(user), notice: t('controllers.application.sign_in.signin_pass')
    else
      redirect_to sign_in_path, alert: t('alerts.session_fail')
    end
  end

  # Creates the Session record and sets the secure cookie.
  # Returns the session record on success, nil on failure.
  #
  # Fails closed for records that are not login-active (merged into another account,
  # inactive, or suspended). This is the single chokepoint for both password sign-in
  # and 2FA completion, so a duplicate retired mid-flow cannot finish authenticating.
  #
  # Locks the user row before requalifying so a concurrent merge and a concurrent sign-in
  # can never interleave: either the merge commits first and this reload sees the retired
  # record and fails closed, or this session is created and committed first and the merge
  # -- which takes the same lock -- must wait behind it.
  #
  # For password sign-in, also re-resolves the exact submitted identifier and reauthenticates
  # the exact submitted password under the same lock. A merge may reassign the identifier, or
  # a concurrent password change may invalidate the password, while this request waits. The
  # stale pre-lock authentication must not create a session after either authority changes.
  def _create_and_set_session_cookie(user, submitted_login_identifier: nil, submitted_password: nil)
    return unless user

    session_record = nil
    ActiveRecord::Base.transaction do
      locked_user = User.lock_for_merge_integrity!(user).fetch(user.id)
      next unless locked_user.public_login_active?

      if submitted_login_identifier.present?
        resolved_user = User.find_by_login_identifier(submitted_login_identifier)
        next unless resolved_user&.id == locked_user.id
        next unless locked_user.authenticate(submitted_password)
      end

      session_record = locked_user.sessions.new(
        user_agent: request.user_agent,
        ip_address: request.remote_ip
      )
      unless session_record.save
        session_record = nil
        next
      end

      locked_user.track_sign_in!(request.remote_ip) # Assuming this method exists on User model
    end
    return unless session_record

    cookies.signed[:session_token] = _session_cookie_options(session_record.session_token)
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
      # Session creation failed closed (e.g. the record was retired mid-login). Clear all
      # temporary 2FA state, including the challenge, so nothing can be replayed.
      TwoFactorAuth.abort_authentication(session)
      redirect_to sign_in_path, alert: t('alerts.session_fail')
    end
  end

  # Checks if a 2FA authentication process has been initiated
  def two_factor_authentication_initiated?
    TwoFactorAuth.get_temp_user_id(session).present?
  end

  # Finds the user for whom 2FA is in progress. Fails closed for records that are not
  # login-active (merged into another account, inactive, or suspended).
  def find_user_for_two_factor
    user_id = TwoFactorAuth.get_temp_user_id(session)
    return nil unless user_id

    user = User.find(user_id)
    user if user.public_login_active?
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
