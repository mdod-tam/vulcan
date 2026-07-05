# frozen_string_literal: true

# Handles password reset and forced password change functionality
class PasswordsController < ApplicationController
  include SecureErrorSanitizer

  ACCOUNT_ACCESS_RATE_LIMIT = 5
  ACCOUNT_ACCESS_RATE_LIMIT_WINDOW = 1.hour

  skip_before_action :authenticate_user!
  skip_before_action :enforce_required_mfa_enrollment
  before_action :set_user_from_token, only: %i[edit]
  before_action :require_password_change_authorization, only: %i[edit update]
  around_action :with_public_request_locale, only: %i[new create]

  def new; end

  def edit
    # The form to enter new password
    # @user is set by set_user_from_token for reset links.
  end

  def create
    user, delivery_method = find_user_for_account_access
    attempt_account_access_delivery(user, delivery_method)

    redirect_to sign_in_path(locale: public_request_locale_param), notice: account_access_confirmation_message
  end

  def update
    return update_password_from_token if params[:token].present?

    forced_password_change = current_user&.force_password_change?
    service = Users::PasswordUpdateService.new(
      current_user,
      params[:password_challenge],
      params[:password],
      params[:password_confirmation]
    )
    result = service.call
    handle_password_update_result(result, forced_password_change: forced_password_change)
  end

  private

  def handle_password_update_result(result, forced_password_change:)
    if result.success?
      handle_successful_password_update(result, forced_password_change: forced_password_change)
    else
      handle_failed_password_update(result)
    end
  end

  def handle_successful_password_update(result, forced_password_change:)
    flash[:notice] = result.message
    respond_to_password_update_success(forced_password_change: forced_password_change)
  end

  def respond_to_password_update_success(forced_password_change:)
    redirect_path = password_update_redirect_path(forced_password_change: forced_password_change)

    respond_to do |format|
      format.turbo_stream { redirect_to redirect_path, status: :see_other, notice: flash[:notice] }
      format.html { redirect_to redirect_path, notice: flash[:notice] }
    end
  end

  def password_update_redirect_path(forced_password_change:)
    return sign_in_path unless current_user
    return _dashboard_for(current_user) if current_user.second_factor_enabled?
    return setup_two_factor_authentication_path if mfa_required_for_current_user?
    return welcome_path if forced_password_change

    _dashboard_for(current_user)
  end

  def handle_failed_password_update(result)
    flash.now[:alert] = result.message
    render :edit, status: :unprocessable_content
  end

  def set_user_from_token
    return if params[:token].blank?

    @user = User.find_by_token_for(:password_reset, params[:token])
    redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless @user
  end

  def require_password_change_authorization
    return if params[:token].present?
    return if current_user.present?

    redirect_to new_password_path, alert: 'Use your account access link to reset your password.'
  end

  def find_user_for_account_access
    contact = account_access_contact.to_s.strip.presence
    return [nil, nil] if contact.blank?

    User.find_for_account_access(contact)
  end

  def account_access_contact
    params[:contact].presence || params[:email].presence || params[:phone].presence
  end

  def attempt_account_access_delivery(user, delivery_method)
    return false if user.blank?

    handle_account_access_request(user, delivery_method)
  end

  def handle_account_access_request(user, delivery_method)
    if account_access_rate_limited?(user)
      log_account_access_attempt(user, delivery_method.presence || :none, 'rate_limited')
      return false
    end

    if delivery_method.blank?
      log_account_access_attempt(user, :none, 'delivery_unavailable')
      return false
    end

    return false unless send_account_access_instructions(user, delivery_method)

    log_account_access_attempt(user, delivery_method, 'sent')
    true
  end

  def account_access_rate_limited?(user)
    count = Rails.cache.increment(account_access_rate_limit_key(user), 1, expires_in: ACCOUNT_ACCESS_RATE_LIMIT_WINDOW)

    count.to_i > ACCOUNT_ACCESS_RATE_LIMIT
  end

  def account_access_rate_limit_key(user)
    hashed_scope = Digest::SHA256.hexdigest("#{user.id}:#{request.remote_ip}")
    "account_access:#{hashed_scope}"
  end

  def log_account_access_attempt(user, delivery_method, status)
    AuditEventService.log(
      action: "account_access_instructions_#{status}",
      actor: user,
      auditable: user,
      metadata: {
        delivery_method: delivery_method.to_s,
        ip_address: request.remote_ip,
        request_id: request.request_id
      }
    )
  rescue StandardError => e
    Rails.logger.warn("Unable to audit account access request for user #{user.id}: #{e.message}")
  end

  def send_account_access_instructions(user, delivery_method)
    if delivery_method == :sms
      SmsService.send_message(
        user.phone,
        account_access_sms_body(user),
        sensitive: true,
        context: { recipient_id: user.id, recipient_channel: 'account_access_sms' }
      )
    else
      UserMailer.with(user: user).password_reset.deliver_later
    end
    true
  rescue StandardError => e
    log_account_access_attempt(user, delivery_method, 'delivery_failed')
    Rails.logger.warn(
      "Unable to send account access instructions for user #{user.id}: #{e.class}: #{sanitize_secure_error_message(e.message)}"
    )
    false
  end

  def account_access_sms_body(user)
    token = user.generate_token_for(:password_reset)
    reset_url = edit_password_url(token: token, **canonical_public_url_options)
    locale = account_access_sms_locale_for(user)

    I18n.t('passwords.account_access_sms.message', locale: locale, reset_url: reset_url)
  end

  def account_access_sms_locale_for(user)
    if user.respond_to?(:effective_locale)
      user.effective_locale.presence || user.locale
    else
      user.locale
    end.presence || I18n.default_locale
  end

  def update_password_from_token
    @user = User.find_by_token_for(:password_reset, params[:token])
    return redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless @user

    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = 'New password and confirmation do not match.'
      return render :edit, status: :unprocessable_content
    end

    if @user.update(password: params[:password], password_confirmation: params[:password_confirmation], force_password_change: false)
      redirect_to sign_in_path, notice: 'Password successfully updated.'
    else
      flash.now[:alert] = "Unable to update password. Please check requirements., #{@user.errors.full_messages.join(', ')}"
      render :edit, status: :unprocessable_content
    end
  end

  def account_access_confirmation_message
    I18n.t(
      'portal_self_service.account_access.confirmation',
      support_email: account_access_support_email,
      support_phone: ProgramContact.support_phone_display
    )
  end

  def account_access_support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end
end
