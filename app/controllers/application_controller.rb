# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Authentication
  include Pagy::Frontend

  protect_from_forgery with: :exception

  add_flash_types :info, :error, :success, :warning

  helper PasswordFieldHelper
  helper EmailStatusHelper
  helper_method :dashboard_path_for_current_user, :mfa_required_for_current_user?,
                :public_form_locale_param, :public_request_locale_param

  before_action :check_password_change_required
  before_action :enforce_required_mfa_enrollment

  def default_url_options
    if Rails.env.production?
      # Production requires APPLICATION_HOST.
      { host: ENV.fetch('APPLICATION_HOST'), protocol: 'https' }
    else
      {}
    end
  end

  private

  def check_password_change_required
    return unless current_user&.force_password_change?

    return if controller_name == 'passwords' && %w[edit update].include?(action_name)

    # Return to this path after the password change.
    store_location if request.get? && !request.xhr?

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

  # These public auth flows use only the request locale. An account locale could reveal that the account exists.
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

  # These flash messages apply to the current render.
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

  # Creates a session, sets the cookie, records sign-in, and redirects.
  # Call this method after password or 2FA authentication.
  #
  # +submitted_login_identifier+ and +submitted_password+ are the exact credentials from password sign-in.
  # 2FA completion omits both. Only the immediate recheck under the user lock uses them.
  # This method does not store these credentials in the session or cookies.
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

  # Creates a Session and sets its signed cookie after the transaction completes.
  # Returns the session, or nil if the user is ineligible or the session cannot save.
  #
  # Password sign-in and 2FA completion both reject merged, inactive, or suspended users here.
  # The shared user lock serializes these writes with a merge of the same user.
  # If the merge commits first, this path reloads the retired user and rejects sign-in.
  # If sign-in acquires the lock first, the merge waits for the session transaction to complete.
  #
  # Password sign-in resolves the exact submitted identifier and authenticates the submitted password under the same lock.
  # A merge can reassign the identifier. A password change can invalidate the password while this request waits.
  # Authentication before the lock must not authorize a session after either change.
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

      locked_user.track_sign_in!(request.remote_ip)
    end
    return unless session_record

    cookies.signed[:session_token] = _session_cookie_options(session_record.session_token)
    session_record
  end

  def _session_cookie_options(token)
    {
      value: token,
      httponly: true,
      secure: Rails.env.production?
      # Consider an explicit SameSite attribute for the session cookie:
      # same_site: :lax # or :strict depending on your needs
    }
  end

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

  def complete_two_factor_authentication(user)
    # Read the return path before 2FA completion removes it.
    stored_location = TwoFactorAuth.get_return_path(session) || session.delete(:return_to)

    # Preserve the challenge until session creation succeeds.
    TwoFactorAuth.complete_authentication(session)

    session_record = _create_and_set_session_cookie(user)

    if session_record
      # Clear the challenge only after session creation succeeds.
      TwoFactorAuth.clear_challenge(session)
      redirect_to stored_location || _dashboard_for(user), notice: t('controllers.application.complete_two_factor_authentication.signin_pass_2fa')
    else
      # A rejected session must clear temporary 2FA state, including the challenge, to prevent replay.
      TwoFactorAuth.abort_authentication(session)
      redirect_to sign_in_path, alert: t('alerts.session_fail')
    end
  end

  def two_factor_authentication_initiated?
    TwoFactorAuth.get_temp_user_id(session).present?
  end

  # A pending 2FA user must remain login-active: not merged, inactive, or suspended.
  def find_user_for_two_factor
    user_id = TwoFactorAuth.get_temp_user_id(session)
    return nil unless user_id

    user = User.find(user_id)
    user if user.public_login_active?
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def ensure_two_factor_initiated
    redirect_to sign_in_path unless two_factor_authentication_initiated?
  end

  def ensure_user_not_authenticated
    redirect_to root_path if current_user
  end

  alias ensure_login_initiated ensure_two_factor_initiated
end
