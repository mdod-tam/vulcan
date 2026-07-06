# frozen_string_literal: true

class RegistrationsController < ApplicationController
  # Require authentication for all actions except new and create
  skip_before_action :authenticate_user!, only: %i[new create]

  # Set the current user for actions that require authentication
  before_action :set_user, only: %i[edit update destroy]
  around_action :with_public_request_locale, only: %i[new create]

  # GET /sign_up
  def new
    @user = User.new
    @user.portal_self_registration = true
    @user.phone_type = :contact_email
  end

  # GET /edit_registration
  def edit
    @user = current_user
    redirect_to sign_in_path, alert: 'You need to sign in to access this page.' unless @user
  end

  def create
    build_user
    duplicate_detection = detect_registration_duplicates

    if duplicate_detection.hard_block
      case duplicate_detection.public_outcome
      when :redirect_sign_in
        return redirect_existing_email_account
      when :support_only
        return render_duplicate_account_prompt
      end
    end

    if @user.save
      open_registration_duplicate_review_case(duplicate_detection) if duplicate_detection.recommended_action == :flag
      create_session_and_cookie
      track_sign_in
      send_registration_confirmation

      @user.reload
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
    @user.portal_self_registration = true
    @user.phone_type_submitted = registration_params[:phone_type].present?
    @user.phone_type = nil if @user.phone.present? && !@user.phone_type_submitted
  end

  def detect_registration_duplicates
    result = DuplicateDetectionService.new(
      context: :public_registration,
      attrs: registration_duplicate_detection_attrs
    ).call
    return result.data if result.success?

    Rails.logger.warn("Registration duplicate detection failed: #{result.message}")
    DuplicateDetectionService::Result.new([], 0.0, [], false, :allow, :proceed)
  end

  def redirect_existing_email_account
    redirect_to sign_in_path(locale: public_form_locale_param),
                notice: t('portal_self_service.registrations.existing_email_account')
  end

  def render_duplicate_account_prompt
    @registration_support_needed = true
    @hide_public_auth_links = true
    @support_email = support_email
    @support_phone = support_phone
    @support_videophone = ProgramContact.support_videophone
    @support_videophone_label = ProgramContact.support_videophone_label
    render :new, status: :unprocessable_content
  end

  def open_registration_duplicate_review_case(duplicate_detection)
    actor = PublicAuditActor.system_audit_actor
    unless actor
      Rails.logger.warn('Registration duplicate review case skipped: no configured public audit actor')
      return
    end

    result = DuplicateReviewCases::CreateService.new(
      source: :registration_soft_match,
      subject_user: @user,
      actor: actor,
      reason_codes: duplicate_detection.reasons,
      candidates: duplicate_review_candidates_for(duplicate_detection),
      metadata: { intake_context: 'registration' }
    ).call
    Rails.logger.warn("Registration duplicate review case failed: #{result.message}") if result.failure?
  end

  def duplicate_review_candidates_for(duplicate_detection)
    duplicate_detection.matched_users.map do |candidate|
      DuplicateReviewCases::CreateService::CandidateInput.new(
        candidate,
        duplicate_detection.reasons.first,
        {
          email_backed_public_portal_account: candidate.email_backed_public_portal_account?,
          real_email: candidate.real_email?,
          real_phone: candidate.real_phone?
        }
      )
    end
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
             :communication_preference, :newsletter_signup,
             # Address fields for letter notifications
             :physical_address_1, :physical_address_2,
             :city, :state, :zip_code]
    )
  end

  def registration_duplicate_detection_attrs
    {
      email: registration_params[:email],
      phone: registration_params[:phone],
      first_name: @user.first_name,
      last_name: @user.last_name,
      date_of_birth: @user.date_of_birth,
      physical_address_1: @user.physical_address_1,
      physical_address_2: @user.physical_address_2,
      city: @user.city,
      state: @user.state,
      zip_code: @user.zip_code
    }
  end

  def support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def support_phone
    ProgramContact.support_phone
  end
end
