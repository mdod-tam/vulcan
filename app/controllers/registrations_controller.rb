# frozen_string_literal: true

class RegistrationsController < ApplicationController
  # Require authentication for all actions except new and create
  skip_before_action :authenticate_user!, only: %i[new create]

  # Set the current user for actions that require authentication
  before_action :set_user, only: %i[edit update destroy]

  # GET /sign_up
  def new
    @user = User.new
  end

  # GET /edit_registration
  def edit
    @user = current_user
    redirect_to sign_in_path, alert: 'You need to sign in to access this page.' unless @user
  end

  def create
    build_user

    # Check for potential duplicates based on Name + DOB and flag for admin review
    @user.needs_duplicate_review = true if potential_duplicate_found?(@user)

    if @user.save
      create_session_and_cookie
      track_sign_in
      send_registration_confirmation

      redirect_to welcome_path, notice: 'Account created successfully. Welcome!'
    else
      render :new, status: :unprocessable_content
    end
  end

  # PATCH/PUT /update_registration
  def update
    if @user.update(registration_params)
      redirect_to root_path, notice: 'Your account was successfully updated.'
    else
      flash.now[:alert] = 'There was a problem updating your account.'
      render :edit
    end
  end

  # DELETE /delete_account
  def destroy
    if @user.destroy
      session[:user_id] = nil
      redirect_to sign_in_path, notice: 'Your account has been deleted.'
    else
      redirect_to edit_registration_path, alert: 'There was a problem deleting your account.'
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_user
    @user = current_user
    redirect_to sign_in_path, alert: 'You need to sign in to access this page.' unless @user
  end

  def build_user
    @user = User.new(registration_params)
    @user.type = 'Users::Constituent'
    @user.force_password_change = false
  end

  def create_session_and_cookie
    @session = @user.sessions.create!(
      user_agent: request.user_agent,
      ip_address: request.remote_ip
    )
    cookies.signed[:session_token] = {
      value: @session.session_token,
      httponly: true,
      permanent: true
    }
  end

  def track_sign_in
    @user.track_sign_in!(request.remote_ip)
  end

  def send_registration_confirmation
    # Delegate confirmation logic to RegistrationConfirmationService
    result = Users::RegistrationConfirmationService.new(user: @user, request: request).call

    return if result.success?

    Rails.logger.error("Registration confirmation failed: #{result.message}")
  end

  def registration_params
    params.expect(
      user: [:email, :password, :password_confirmation,
             :first_name, :last_name, :middle_initial,
             :date_of_birth, :phone, :phone_type, :timezone, :locale,
             :hearing_disability, :vision_disability,
             :speech_disability, :mobility_disability, :cognition_disability,
             :communication_preference,
             # Address fields for letter notifications
             :physical_address_1, :physical_address_2,
             :city, :state, :zip_code,
             :needs_duplicate_review]
    )
  end

  # Helper method for the soft duplicate check
  def potential_duplicate_found?(user)
    # Normalize inputs for comparison
    normalized_first_name = user.first_name&.strip&.downcase
    normalized_last_name = user.last_name&.strip&.downcase

    # Check only if all parts are present
    return false unless normalized_first_name.present? && normalized_last_name.present? && user.date_of_birth.present?

    # Correctly use where(...).exists? for multiple conditions
    User.exists?(['lower(first_name) = ? AND lower(last_name) = ? AND date_of_birth = ?', normalized_first_name, normalized_last_name, user.date_of_birth])
  end
end
