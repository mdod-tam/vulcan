# frozen_string_literal: true

# Handles password reset and forced password change functionality
class PasswordsController < ApplicationController
  skip_before_action :authenticate_user!
  before_action :set_user, only: %i[edit] # set_user is only for token-based password resets

  def new; end

  def edit
    # The form to enter new password
    # @user is set by set_user
  end

  def create
    @user = User.find_by_email(params[:email])
    if @user
      # Generate reset token and send email
      @user.generate_password_reset_token!
      # UserMailer.password_reset(@user).deliver_later # You'll need to create this mailer
      redirect_to sign_in_path, notice: 'Check your email for password reset instructions.'
    else
      redirect_to new_password_path, alert: 'Email address not found.'
    end
  end

  def update
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

  def set_user
    return if params[:token].blank?

    @user = User.find_by_token_for(:password_reset, params[:token])
    redirect_to new_password_path, alert: 'Invalid or expired reset link.' unless @user
  end
end
