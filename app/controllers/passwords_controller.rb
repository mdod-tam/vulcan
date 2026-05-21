# frozen_string_literal: true

# Handles password reset and forced password change functionality
class PasswordsController < ApplicationController
  ACCOUNT_ACCESS_RATE_LIMIT = 5
  ACCOUNT_ACCESS_RATE_LIMIT_WINDOW = 1.hour

  skip_before_action :authenticate_user!
  before_action :set_user_from_token, only: %i[edit]

  def new; end

  def edit
    # The form to enter new password
    # @user is set by set_user
  end

  def create
    user, delivery_method = find_user_for_account_access
    handle_account_access_request(user, delivery_method) if user.present?

    redirect_to sign_in_path, notice: account_access_confirmation_message
  end

  def update
    return update_password_from_token if params[:token].present?

    service = Users::PasswordUpdateService.new(
      current_user,
      params[:password_challenge],
      params[:password],
      params[:password_confirmation]
    )
    result = service.call
    handle_password_update_result(result)
  end

  private

  def handle_password_update_result(result)
    if result.success?
      handle_successful_password_update(result)
    else
      handle_failed_password_update(result)
    end
  end

  def handle_successful_password_update(result)
    flash[:notice] = result.message
    respond_to_password_update_success
  end

  def respond_to_password_update_success
    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to sign_in_path, notice: flash[:notice] }
    end
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

  def find_user_for_account_access
    contact = account_access_contact
    email_user = User.find_by_email(contact)
    return [email_user, :email] if email_user.present?

    phone_user = User.find_by_phone(contact)
    return [phone_user, :sms] if phone_user.present?

    [nil, nil]
  end

  def account_access_contact
    params[:contact].presence || params[:email].presence || params[:phone].presence
  end

  def handle_account_access_request(user, delivery_method)
    if account_access_rate_limited?(user)
      log_account_access_attempt(user, delivery_method, 'rate_limited')
      return
    end

    send_account_access_instructions(user, delivery_method)
    log_account_access_attempt(user, delivery_method, 'sent')
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
      SmsService.send_message(user.phone, account_access_sms_body(user))
    else
      UserMailer.with(user: user).password_reset.deliver_later
    end
  rescue StandardError => e
    log_account_access_attempt(user, delivery_method, 'delivery_failed')
    Rails.logger.warn("Unable to send account access instructions for user #{user.id}: #{e.class}: #{e.message}")
  end

  def account_access_sms_body(user)
    token = user.generate_token_for(:password_reset)
    reset_url = edit_password_url(token: token, host: request.host, protocol: request.protocol)
    "Use this MAT account access link to set your password: #{reset_url} This link expires in 20 minutes."
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
    'If the information you entered matches an account, we sent account access instructions to the contact information on record.'
  end
end
