# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user
    before_action :authenticate_user!
  end

  def require_role(role)
    return if current_user&.send("#{role}?")

    redirect_to root_path, alert: 'Unauthorized access'
  end

  private

  # Retrieves the currently logged-in user based on the session_token stored in cookies
  def current_user
    return @current_user if defined?(@current_user)

    # Load current session first to avoid redundant DB queries
    current_session

    # Return the already loaded user from the session if possible
    candidate = @current_session&.user

    # A session created before the user was merged/deactivated must not keep
    # authenticating them on later requests: session destruction at retirement time
    # (e.g. Users::DuplicateMergeService#expire_duplicate_sessions!) is the normal path,
    # but this is the authoritative recheck so any status change closes the session
    # immediately, not only when the code path that caused it remembered to expire it.
    if candidate && !candidate.public_login_active?
      invalidate_stale_session!
      candidate = nil
    end

    @current_user = candidate

    # Set Current.user for the request context - needed for verify_authentication_state
    Current.user = @current_user if @current_user.present?

    @current_user
  end

  # Destroys a session whose user is no longer login-active and clears the cookie so
  # the browser stops presenting a token for a session that can never authenticate.
  def invalidate_stale_session!
    @current_session.destroy if @current_session&.persisted?
    @current_session = nil
    cookies.delete(:session_token)
  end

  # Load and cache the current session
  def current_session
    return @current_session if defined?(@current_session)

    @current_session = if Rails.env.test?
                         find_test_session
                       else
                         # Production environment - use signed cookies only
                         find_production_session
                       end

    # Check for expired session
    if @current_session.respond_to?(:expired?) && @current_session.expired?
      @current_session = nil
      cookies.delete(:session_token)
    end

    @current_session
  end

  def find_production_session
    return if cookies.signed[:session_token].blank?

    # Load session without eager loading user; association is loaded on demand when needed.
    Session.find_by(session_token: cookies.signed[:session_token])
  end

  def find_test_session
    # Try test user sources in priority order
    find_current_test_user ||
      find_header_test_user ||
      find_env_test_user ||
      find_cookie_session
  end

  def find_current_test_user
    return unless defined?(Current) && Current.test_user_id.present?

    create_test_session_for_user_id(Current.test_user_id)
  end

  def find_header_test_user
    test_user_id = request.headers['X-Test-User-Id'] || request.headers['HTTP_X_TEST_USER_ID']
    return if test_user_id.blank?

    create_test_session_for_user_id(test_user_id)
  end

  def find_env_test_user
    return if ENV['TEST_USER_ID'].blank?

    create_test_session_for_user_id(ENV.fetch('TEST_USER_ID', nil))
  end

  def create_test_session_for_user_id(user_id)
    test_user = User.find_by(id: user_id)
    Session.new(user: test_user) if test_user
  end

  def find_cookie_session
    find_signed_cookie_session || find_unsigned_cookie_session
  end

  def find_signed_cookie_session
    return if cookies.signed[:session_token].blank?

    Session.find_by(session_token: cookies.signed[:session_token])
  end

  def find_unsigned_cookie_session
    return if cookies[:session_token].blank?

    Session.find_by(session_token: cookies[:session_token])
  end

  # Redirects unauthenticated users to the sign-in page with an alert message
  def authenticate_user!
    return if current_user.present?

    store_location
    redirect_to sign_in_path, alert: 'Please sign in to continue' and return
  end

  def store_location
    session[:return_to] = request.fullpath if request.get? || request.head?
  end

  # Restricts access to admin users only
  def require_admin!
    return if current_user.admin?

    redirect_to root_path, alert: 'Unauthorized access'
  end

  def require_evaluator!
    return if current_user.evaluator? || current_user.admin?

    redirect_to root_path, alert: 'Unauthorized access'
  end
end
