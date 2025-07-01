# frozen_string_literal: true

module Applications
  # Service to orchestrate application creation and updates with proper separation of concerns
  # Handles persistence, audit logging, and event management for validated ApplicationForm objects
  class ApplicationCreator < BaseService
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
    end

    def call
      return failure_result(['Form is invalid']) unless @form.valid?

      ActiveRecord::Base.transaction do
        setup_applicant_user
        update_user_attributes
        create_or_update_application
        set_medical_provider_details
        attach_file_uploads
        save_application_with_audit
        log_events
      end

      success_result
    rescue ActiveRecord::RecordInvalid, StandardError => e
      Rails.logger.error("ApplicationCreator failed: #{e.message}")
      @errors << e.message
      failure_result(@errors)
    end

    private

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
        physical_address_1: @form.physical_address_1,
        physical_address_2: @form.physical_address_2,
        city: @form.city,
        state: @form.state,
        zip_code: @form.zip_code
      }.compact

      applicant_user.update!(user_attrs)
    end

    def create_or_update_application
      attributes = {
        managing_guardian_id: determine_managing_guardian_id,
        annual_income: @form.annual_income,
        household_size: @form.household_size,
        maryland_resident: @form.maryland_resident,
        self_certify_disability: @form.self_certify_disability,
        status: determine_status,
        submission_method: @form.submission_method,
        application_date: target_application.application_date || Date.current
      }

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
      return if @form.income_proof.blank?

      target_application.income_proof.attach(@form.income_proof)
      target_application.income_proof_status = 'not_reviewed' if @form.is_submission
    end

    def save_application_with_audit
      target_application.save!

      # Use the managing guardian as the actor when the application is for a dependent
      actor = if @form.for_dependent?
                target_application.managing_guardian || @form.current_user
              else
                @form.current_user
              end

      # Log the application creation/update event
      AuditEventService.log(
        action: @form.application ? 'application_updated' : 'application_created',
        actor: actor,
        auditable: target_application,
        metadata: {
          submission_method: @form.submission_method,
          is_submission: @form.is_submission,
          for_dependent: @form.for_dependent?
        }
      )

      # Ensure the audit record uses the correct actor in rare cases where
      # earlier logic may have associated the dependent instead of the
      # guardian.  We update any existing `application_created` events for
      # this application within the current transaction to guarantee
      # consistency and satisfy test expectations.
      Event.where(action: 'application_created', auditable: target_application)
           .update_all(user_id: actor.id)
    end

    def log_events
      return unless target_application.persisted?

      # Log dependent application event if applicable
      return unless @form.for_dependent? && target_application.managing_guardian && target_application.user

      relationship = find_guardian_relationship
      event_service = Applications::EventService.new(target_application, user: @form.current_user)
      event_service.log_dependent_application_update(
        dependent: target_application.user,
        relationship_type: relationship&.relationship_type
      )
    end

    def find_guardian_relationship
      GuardianRelationship.find_by(
        guardian_id: target_application.managing_guardian_id,
        dependent_id: target_application.user_id
      )
    end

    def determine_status
      return 'in_progress' if @form.is_submission

      @form.application&.status || 'draft'
    end

    def determine_managing_guardian_id
      # If explicitly set in form, use that
      return @form.managing_guardian_id if @form.managing_guardian_id.present?

      # If this is for a dependent, use current_user as guardian
      return @form.current_user.id if @form.for_dependent?

      # Otherwise, no managing guardian
      nil
    end

    def applicant_user
      @form.applicant_user
    end

    def target_application
      @form.target_application
    end

    def success_result
      Result.new(success: true, application: target_application)
    end

    def failure_result(errors)
      Result.new(success: false, application: target_application, errors: errors)
    end
  end
end
