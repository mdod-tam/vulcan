# frozen_string_literal: true

module Applications
  # Service to orchestrate application creation and updates with proper separation of concerns
  # Handles persistence, audit logging, and event management for validated ApplicationForm objects
  class ApplicationCreator < BaseService
    class IneligibleApplicantError < StandardError; end

    attr_reader :target_application

    # Result object that provides success/failure status and application access
    class Result
      attr_reader :application, :errors

      def initialize(success:, application: nil, errors: [])
        @success = success
        @application = application
        @errors = Array(errors)
      end

      def success?
        @success
      end

      def failure?
        !success?
      end

      def error_messages
        @errors.map(&:to_s)
      end
    end

    # Create or update an application using a validated ApplicationForm
    # @param form [ApplicationForm] A valid ApplicationForm instance
    # @return [Result] Success/failure result with application
    def self.call(form)
      new(form).call
    end

    def initialize(form)
      super()
      @form = form
      @errors = []
      @target_application = form.target_application
    end

    def call
      return failure_result(['Form is invalid']) unless @form.valid?

      ActiveRecord::Base.transaction do
        lock_and_requalify_applicant!
        setup_applicant_user
        update_user_attributes
        create_or_update_application
        set_medical_provider_details
        attach_file_uploads
        save_application_with_audit
        log_events
      end

      success_result
    rescue IneligibleApplicantError => e
      @errors << e.message
      failure_result(@errors)
    rescue ActiveRecord::RecordInvalid, StandardError => e
      Rails.logger.error("ApplicationCreator failed: #{e.message}")
      @errors << e.message
      failure_result(@errors)
    end

    private

    def lock_and_requalify_applicant!
      current_user_id = @form.current_user&.id
      applicant_id = initial_applicant_id
      raise IneligibleApplicantError, 'This record is no longer an eligible active record.' if current_user_id.blank? || applicant_id.blank?

      guardian_ids = GuardianRelationship.where(dependent_id: applicant_id).pluck(:guardian_id)
      locked_users = User.lock_for_merge_integrity!(
        current_user_id,
        applicant_id,
        guardian_ids,
        @form.managing_guardian_id
      )
      @current_user = locked_users.fetch(current_user_id)
      @applicant_user = locked_users.fetch(applicant_id)

      validate_constituent_participant!(@current_user)
      validate_constituent_participant!(@applicant_user)

      @locked_guardian_relationships = GuardianRelationship
                                       .where(dependent_id: applicant_id)
                                       .order(:id)
                                       .lock
                                       .to_a
      missing_guardian_ids = @locked_guardian_relationships.map(&:guardian_id).uniq - locked_users.keys
      raise IneligibleApplicantError, 'This guardian relationship changed while the application was being saved.' if missing_guardian_ids.any?

      hydrate_guardian_relationships!(locked_users)

      locked_inventory = Application.where(user_id: applicant_id).order(:id).lock.to_a
      replace_with_exact_target!(locked_inventory)
      requalify_application_authority!

      return unless @form.is_submission

      raise IneligibleApplicantError, 'This application is no longer a draft.' unless
        target_application.new_record? || target_application.status_draft?

      error = Application.sibling_application_eligibility_error(
        locked_inventory,
        target_application: target_application
      )
      raise IneligibleApplicantError, error if error
    end

    def initial_applicant_id
      if target_application.persisted?
        Application.where(id: target_application.id).pick(:user_id)
      else
        @form.applicant_user&.id
      end
    end

    def validate_constituent_participant!(user)
      raise IneligibleApplicantError, 'This record is no longer an eligible active record.' unless user.public_login_active?

      return if user.constituent?

      raise IneligibleApplicantError, 'Only constituent records can use the constituent application portal.'
    end

    def hydrate_guardian_relationships!(locked_users)
      @locked_guardian_relationships.each do |relationship|
        relationship.association(:guardian_user).target = locked_users.fetch(relationship.guardian_id)
        relationship.association(:dependent_user).target = @applicant_user
      end
    end

    def replace_with_exact_target!(locked_inventory)
      if target_application.persisted?
        exact_target = locked_inventory.find { |application| application.id == target_application.id }
        raise IneligibleApplicantError, 'This application no longer belongs to this participant.' unless exact_target

        @target_application = exact_target
      end

      target_application.association(:user).target = @applicant_user
    end

    def requalify_application_authority!
      manager_id = target_application.persisted? ? target_application.managing_guardian_id : nil
      @dependent_application = @applicant_user.id != @current_user.id || manager_id.present?

      if dependent_application?
        unless @applicant_user.id != @current_user.id && (!target_application.persisted? || manager_id == @current_user.id)
          raise IneligibleApplicantError, 'This application is no longer managed by this guardian.'
        end
        raise IneligibleApplicantError, 'This guardian relationship is no longer authorized.' unless locked_guardian_relationship

        target_application.association(:managing_guardian).target = @current_user if target_application.persisted?
      elsif target_application.persisted? && target_application.user_id != @current_user.id
        raise IneligibleApplicantError, 'This application no longer belongs to this participant.'
      end
    end

    def setup_applicant_user
      return unless applicant_user

      # Ensure proper STI type
      applicant_user.type = 'Users::Constituent' if applicant_user.type.blank?
    end

    def update_user_attributes
      return unless applicant_user

      user_attrs = {
        hearing_disability: @form.hearing_disability,
        vision_disability: @form.vision_disability,
        speech_disability: @form.speech_disability,
        mobility_disability: @form.mobility_disability,
        cognition_disability: @form.cognition_disability,
        locale: @form.locale
      }.merge(address_attributes).compact

      applicant_user.update!(user_attrs)
    end

    def address_attributes
      return guardian_address_attributes if dependent_application? && @form.use_guardian_address

      {
        physical_address_1: @form.physical_address_1,
        physical_address_2: @form.physical_address_2,
        city: @form.city,
        state: @form.state,
        zip_code: @form.zip_code
      }
    end

    def guardian_address_attributes
      {
        physical_address_1: current_user.physical_address_1,
        physical_address_2: current_user.physical_address_2,
        city: current_user.city,
        state: current_user.state,
        zip_code: current_user.zip_code
      }
    end

    def create_or_update_application
      attributes = {
        managing_guardian_id: determine_managing_guardian_id,
        annual_income: @form.annual_income,
        household_size: @form.household_size,
        maryland_resident: @form.maryland_resident,
        self_certify_disability: @form.self_certify_disability,
        terms_accepted: @form.terms_accepted,
        information_verified: @form.information_verified,
        medical_release_authorized: @form.medical_release_authorized,
        submission_method: @form.submission_method,
        application_date: target_application.application_date || Date.current,
        alternate_contact_name: @form.alternate_contact_name,
        alternate_contact_phone: @form.alternate_contact_phone,
        alternate_contact_email: @form.alternate_contact_email,
        alternate_contact_relationship_type: @form.alternate_contact_relationship_type
      }
      # Submission moves draft -> in_progress via transition_status! after save (canonical audit).
      attributes[:status] =
        if @form.is_submission
          target_application.persisted? ? target_application.status : :draft
        else
          determine_status
        end

      # Only set user if this is a new application or explicitly changing the user
      attributes[:user] = applicant_user if target_application.new_record? || @form.user_id.present?

      target_application.assign_attributes(attributes)
    end

    def set_medical_provider_details
      target_application.medical_provider_name = @form.medical_provider_name if @form.medical_provider_name.present?
      target_application.medical_provider_phone = @form.medical_provider_phone if @form.medical_provider_phone.present?
      target_application.medical_provider_fax = @form.medical_provider_fax if @form.medical_provider_fax.present?
      target_application.medical_provider_email = @form.medical_provider_email if @form.medical_provider_email.present?
    end

    def attach_file_uploads
      # Attach residency proof if provided
      if @form.residency_proof.present?
        target_application.residency_proof.attach(@form.residency_proof)
        target_application.residency_proof_status = 'not_reviewed' if @form.is_submission
      end

      # Attach income proof if provided
      if @form.income_proof.present?
        target_application.income_proof.attach(@form.income_proof)
        target_application.income_proof_status = 'not_reviewed' if @form.is_submission
      end

      # Attach ID proof if provided
      return if @form.id_proof.blank?

      target_application.id_proof.attach(@form.id_proof)
      target_application.id_proof_status = 'not_reviewed' if @form.is_submission
    end

    def save_application_with_audit
      was_new_record = target_application.new_record?
      target_application.save!
      actor = determine_audit_actor

      if was_new_record
        log_application_created_event(actor)
      elsif should_log_application_updated_event?
        log_application_updated_event(actor)
      end

      target_application.submit!(actor: actor) if @form.is_submission
    end

    def determine_audit_actor
      current_user
    end

    def log_application_created_event(actor)
      Rails.logger.debug { "Logging application_created event for application #{target_application.id}" }
      begin
        event = AuditEventService.log(
          action: 'application_created',
          actor: actor,
          auditable: target_application,
          metadata: {
            submission_method: @form.submission_method,
            initial_status: target_application.status
          }
        )
        if event
          Rails.logger.debug { "Successfully logged application_created event: #{event.id}" }
        else
          Rails.logger.error 'AuditEventService returned nil for application_created event'
        end
      rescue StandardError => e
        Rails.logger.error "Error logging application_created event: #{e.message}"
        raise
      end
    end

    def log_application_updated_event(actor)
      Rails.logger.debug { "Logging application_updated event for application #{target_application.id}" }
      AuditEventService.log(
        action: 'application_updated',
        actor: actor,
        auditable: target_application,
        metadata: {
          submission_method: @form.submission_method
        }
      )
    end

    def should_log_application_updated_event?
      target_application.saved_changes.except('updated_at').any?
    end

    def log_events
      return unless target_application.persisted?

      # Log dependent application event if applicable
      return unless dependent_application? && target_application.managing_guardian && target_application.user

      relationship = find_guardian_relationship
      event_service = Applications::EventService.new(target_application, user: current_user)
      event_service.log_dependent_application_update(
        dependent: target_application.user,
        relationship_type: relationship&.relationship_type
      )
    end

    def find_guardian_relationship
      locked_guardian_relationship
    end

    def determine_status
      @form.application&.status || 'draft'
    end

    def determine_managing_guardian_id
      # If updating existing application, preserve existing managing_guardian_id
      return target_application.managing_guardian_id if target_application.persisted? && target_application.managing_guardian_id.present?

      dependent_application? ? current_user.id : nil
    end

    def applicant_user
      @applicant_user || @form.applicant_user
    end

    def current_user
      @current_user || @form.current_user
    end

    def dependent_application?
      @dependent_application == true
    end

    def locked_guardian_relationship
      @locked_guardian_relationships&.find do |relationship|
        relationship.guardian_id == current_user.id && relationship.dependent_id == applicant_user.id
      end
    end

    def success_result
      Result.new(success: true, application: target_application)
    end

    def failure_result(errors)
      Result.new(success: false, application: target_application, errors: errors)
    end
  end
end
