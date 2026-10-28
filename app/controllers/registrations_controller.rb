# frozen_string_literal: true

class RegistrationsController < ApplicationController
  class DuplicateReviewCaseRequired < StandardError; end

  # Require authentication for all actions except new and create
  skip_before_action :authenticate_user!, only: %i[new create]

  around_action :with_public_request_locale, only: %i[new create]

  # GET /sign_up
  def new
    @user = User.new
    @user.portal_self_registration = true
    @user.phone_type = :contact_email
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

    if save_user_with_duplicate_review!(duplicate_detection)
      unless _create_and_set_session_cookie(@user)
        redirect_to sign_in_path(locale: public_form_locale_param), alert: t('alerts.session_fail')
        return
      end
      send_registration_confirmation

      @user.reload
      redirect_to welcome_path, notice: t('portal_self_service.registrations.account_created')
    else
      render :new, status: :unprocessable_content
    end
  end

  private

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

    Rails.logger.warn('Registration duplicate detection failed')
    DuplicateDetectionService::Result.new([], 0.0, [], false, :allow, :proceed)
  end

  def save_user_with_duplicate_review!(duplicate_detection)
    ActiveRecord::Base.transaction do
      @user.save!
      require_registration_duplicate_review_case!(duplicate_detection) if duplicate_detection.recommended_action == :flag
    end

    true
  rescue ActiveRecord::RecordInvalid
    false
  rescue DuplicateReviewCaseRequired
    Rails.logger.warn('Registration rolled back because duplicate review case could not be opened')
    false
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("Registration rolled back because duplicate review case failed: #{e.class.name}")
    @user.errors.add(:base, t('portal_self_service.registrations.registration_blocked_heading')) if @user.errors.empty?
    false
  end

  def require_registration_duplicate_review_case!(duplicate_detection)
    return if open_registration_duplicate_review_case(duplicate_detection)

    @user.errors.add(:base, t('portal_self_service.registrations.registration_blocked_heading'))
    raise DuplicateReviewCaseRequired
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
      return false
    end

    result = DuplicateReviewCases::CreateService.new(
      source: :registration_soft_match,
      subject_user: @user,
      actor: actor,
      reason_codes: duplicate_detection.reasons,
      candidates: duplicate_review_candidates_for(duplicate_detection),
      metadata: { intake_context: 'registration' }
    ).call
    if result.failure?
      Rails.logger.warn("Registration duplicate review case failed for user #{@user.id}")
      return false
    end

    true
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

  def send_registration_confirmation
    result = Users::RegistrationConfirmationService.new(user: @user, request: request).call

    return if result.success?

    Rails.logger.error("Registration confirmation failed for user #{@user.id}")
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
    ProgramContact.support_email
  end

  def support_phone
    ProgramContact.support_phone
  end
end
