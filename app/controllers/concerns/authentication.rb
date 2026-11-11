# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :session_activity_deadlines
    before_action :authenticate_user!
  end

  private

  def presented_session_token
    return @presented_session_token if defined?(@presented_session_token)

    @presented_session_token = cookies.signed[:session_token]
  end

  def session_activity_deadlines
    return unless current_user && current_session&.persisted?
    return if current_user.force_password_change?
    return if mfa_required_for_current_user? && !current_user.second_factor_enabled?

    current_session.activity_deadlines
  end

  def current_user
    return @current_user if defined?(@current_user)

    current_session

    @current_user = @current_session&.user

    # Current.user supplies the actor for request-scoped audit events.
    Current.user = @current_user if @current_user.present?

    @current_user
  end

  def current_session
    return @current_session if defined?(@current_session)

    @current_session = find_production_session

    clear_expired_session if @current_session&.expired?
    if @current_session && !@current_session.user.public_login_active?
      @current_session.destroy! if @current_session.persisted?
      clear_expired_session
    end

    @current_session
  end

  def find_production_session
    return if cookies.signed[:session_token].blank?

    Session.for_token(presented_session_token).take
  end

  # JSON callers need a 401 response. The sign-in action has no JSON responder.
  # Use the format, not xhr?, because Turbo callers need the sign-in redirect.
  def authenticate_user!
    if current_user.present?
      # Recheck activity here because subclasses can reorder this callback.
      return if track_session_activity? ? current_session.record_activity! : !current_session.expired?

      clear_expired_session
    end

    return render_json_authentication_required if request.format.json?

    store_location
    locale = @expired_session_locale || public_request_locale
    redirect_locale = locale unless locale.to_s == I18n.default_locale.to_s
    alert_key = @expired_session_locale ? 'alerts.session_expired' : 'alerts.sign_in_required'
    redirect_to sign_in_path(locale: redirect_locale), alert: I18n.t(alert_key, locale: locale)
  end

  def track_session_activity? = true

  def clear_expired_session
    @expired_session_locale = public_request_locale_param || @current_session&.user&.effective_message_locale || I18n.default_locale
    clear_session_authentication
  end

  def clear_session_authentication
    @current_session = nil
    @current_user = nil
    Current.user = nil
    cookies.delete(:session_token)
    reset_session
  end

  # A cached failure would remain stale after the user signs in.
  def render_json_authentication_required
    response.headers['Cache-Control'] = 'no-store'
    render json: { error: 'authentication_required', sign_in_path: sign_in_path },
           status: :unauthorized
  end

  def store_location
    session[:return_to] = request.fullpath if request.get? || request.head?
  end

  # The role guards for portals and admin pages. Every refusal sends the user home with one localized notice.
  def require_admin!
    deny_role_access unless current_user&.admin?
  end

  def require_constituent!
    deny_role_access unless current_user&.constituent?
  end

  def require_evaluator!
    deny_role_access unless current_user&.assignable_evaluator?
  end

  def deny_role_access
    redirect_to root_path, alert: t('alerts.unauthorized_action')
  end
end
