# frozen_string_literal: true

# Handles password reset and forced password change functionality
class PasswordsController < ApplicationController
  include SecureErrorSanitizer

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
    @account_access_contact = account_access_contact.to_s.strip.presence
    if (rate_limit_scope = pre_lookup_account_access_rate_limit_scope(@account_access_contact))
      log_public_account_access_rate_limit(rate_limit_scope)
      return redirect_to_account_access_confirmation
    end

    user, delivery_method = find_user_for_account_access(@account_access_contact)
    attempt_account_access_delivery(user, delivery_method)

    redirect_to_account_access_confirmation
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
    @user = nil unless @user&.public_login_active?
    redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless @user
  end

  def require_password_change_authorization
    return if params[:token].present?
    return if current_user.present?

    redirect_to new_password_path, alert: 'Use your account access link to reset your password.'
  end

  def find_user_for_account_access(contact = account_access_contact.to_s.strip.presence)
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
    if user_account_access_rate_limited?(user)
      log_account_access_attempt(user, delivery_method.presence || :none, 'rate_limited', rate_limit_scope: 'user_ip')
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

  def pre_lookup_account_access_rate_limit_scope(contact)
    return :ip if account_access_auth_rate_limited?(:ip)
    return :contact_ip if contact.present? && account_access_auth_rate_limited?(:contact_ip, submitted_contact: contact)

    nil
  end

  def user_account_access_rate_limited?(user)
    account_access_auth_rate_limited?(:user_ip, user: user)
  end

  def account_access_auth_rate_limited?(scope, submitted_contact: nil, user: nil)
    AuthRateLimit.check!(
      action: :account_access,
      scope: scope,
      request: request,
      submitted_contact: submitted_contact,
      user_id: user&.id
    )
    false
  rescue AuthRateLimit::ExceededError
    true
  end

  def log_account_access_attempt(user, delivery_method, status, metadata = {})
    AuditEventService.log(
      action: "account_access_instructions_#{status}",
      actor: user,
      auditable: user,
      metadata: account_access_audit_metadata.merge(
        { delivery_method: delivery_method.to_s }.merge(metadata)
      )
    )
  rescue StandardError => e
    Rails.logger.warn("Unable to audit account access request for user #{user.id}: #{e.message}")
  end

  def log_public_account_access_rate_limit(rate_limit_scope)
    PublicAuditActor.log_audit(
      action: 'account_access_instructions_rate_limited',
      metadata: account_access_audit_metadata.merge(rate_limit_scope: rate_limit_scope.to_s)
    )
  end

  def account_access_audit_metadata
    metadata = {
      request_ip_digest: AuthRateLimit.request_ip_digest(request),
      request_id: request.request_id
    }
    metadata[:submitted_contact_digest] = AuthRateLimit.contact_digest(@account_access_contact) if @account_access_contact.present?
    metadata
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
    @user = nil unless @user&.public_login_active?
    return redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless @user

    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = 'New password and confirmation do not match.'
      return render :edit, status: :unprocessable_content
    end

    token_still_valid = false
    password_updated = false
    @user.with_lock do
      resolved_user = User.find_by_token_for(:password_reset, params[:token])
      next unless resolved_user&.id == @user.id && @user.public_login_active?

      token_still_valid = true
      password_updated = @user.update(
        password: params[:password],
        password_confirmation: params[:password_confirmation],
        force_password_change: false
      )
    end

    return redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless token_still_valid

    if password_updated
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

  def redirect_to_account_access_confirmation
    redirect_to sign_in_path(locale: public_request_locale_param), notice: account_access_confirmation_message
  end
end
