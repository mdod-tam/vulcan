# frozen_string_literal: true

class PasswordsController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :enforce_required_mfa_enrollment
  before_action :set_user_from_token, only: %i[edit]
  before_action :require_password_change_authorization, only: %i[edit update]
  around_action :with_public_request_locale, only: %i[new create]

  def new; end

  def edit; end

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
    session_record = _create_and_set_session_cookie(
      current_user,
      submitted_login_identifier: current_user.email,
      submitted_password: params[:password]
    )
    redirect_path = if session_record
                      password_update_redirect_path(user: session_record.user, forced_password_change: forced_password_change)
                    else
                      clear_session_authentication
                      sign_in_path
                    end
    flash[:notice] = result.message
    respond_to_password_update_success(redirect_path: redirect_path)
  end

  def respond_to_password_update_success(redirect_path:)
    respond_to do |format|
      format.turbo_stream { redirect_to redirect_path, status: :see_other, notice: flash[:notice] }
      format.html { redirect_to redirect_path, notice: flash[:notice] }
    end
  end

  def password_update_redirect_path(user:, forced_password_change:)
    return _dashboard_for(user) if user.second_factor_enabled?
    return setup_two_factor_authentication_path if mfa_required_for_role?(user)
    return welcome_path if forced_password_change

    _dashboard_for(user)
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
    Rails.logger.warn("Unable to audit account access request for user #{user.id}: #{e.class}")
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
      action = 'SmsService#account_access'
      denial, context = EmailDelivery.issuance(action, channel: 'sms')
      denial&.raise_if_configuration_error!
      if denial
        log_account_access_attempt(user, delivery_method, 'suppressed')
        return false
      end
      SmsService.send_message(
        user.phone,
        account_access_sms_body(user),
        sensitive: true,
        action: action,
        delivery_context: context,
        context: { recipient_id: user.id, recipient_channel: 'account_access_sms' }
      )
    else
      outcome = EmailDelivery.deliver_later(UserMailer.with(user: user).password_reset)
      unless outcome == :queued
        status = case outcome
                 when :suppressed then 'suppressed'
                 when :configuration_error then 'configuration_error'
                 else 'delivery_failed'
                 end
        metadata = outcome == :configuration_error ? { reason: EmailDelivery::Current.denial_decision&.reason } : {}
        log_account_access_attempt(user, delivery_method, status, metadata)
        return false
      end
    end
    true
  rescue ApplicationMailer::DeliverySkipped
    log_account_access_attempt(user, delivery_method, 'suppressed')
    false
  rescue EmailDelivery::ConfigurationError => e
    log_account_access_attempt(user, delivery_method, 'configuration_error', reason: e.reason)
    false
  rescue StandardError => e
    log_account_access_attempt(user, delivery_method, 'delivery_failed')
    Rails.logger.warn(
      "Unable to send account access instructions for user #{user.id}: #{e.class}"
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

    # Lock the user row before requalifying and consuming the token. The lock keeps a
    # concurrent merge and a concurrent reset-password submission from interleaving.
    # Either the merge commits first and this reload sees the retired record and fails
    # closed. Or the password update commits first and the merge waits on the same lock.
    token = params[:token]
    eligible = false
    update_succeeded = false
    ActiveRecord::Base.transaction do
      locked_user = User.lock_for_merge_integrity!(@user).fetch(@user.id)
      eligible = locked_user.public_login_active?
      next unless eligible

      # Re-resolve the token under lock. The unlocked lookup above proves only that the
      # token payload, bound to the password digest, was valid at that moment. A concurrent
      # password change in the window before the lock was granted would already have
      # invalidated it. That change may be a different reset token or an admin reset.
      # Re-verifying against the locked row's current state closes that gap.
      resolved_by_token = User.find_by_token_for(:password_reset, token)
      eligible = resolved_by_token.present? && resolved_by_token.id == locked_user.id
      next unless eligible

      @user = locked_user
      update_succeeded = @user.update(
        password: params[:password],
        password_confirmation: params[:password_confirmation],
        force_password_change: false
      )
    end

    return redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless eligible

    if update_succeeded
      clear_session_authentication if current_user&.id == @user.id
      redirect_to sign_in_path, notice: 'Password successfully updated.'
    else
      flash.now[:alert] = Users::PasswordUpdateService.failure_message(@user)
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
