# frozen_string_literal: true

module Applications
  # This service handles paper application submissions by administrators
  # It follows the same patterns as ConstituentPortal for file uploads
  class PaperApplicationService < BaseService
    include Rails.application.routes.url_helpers

    attr_reader :params, :admin, :application, :constituent, :errors, :guardian_user_for_app

    def initialize(params:, admin:, skip_income_validation: false, skip_proof_processing: false)
      super()
      @params = params.with_indifferent_access
      @admin = admin
      @application = nil
      @constituent = nil
      @guardian_user_for_app = nil
      @errors = []
      @temp_passwords = {}
      @skip_income_validation = skip_income_validation
      @skip_proof_processing = skip_proof_processing
    end

    def create
      Current.paper_context = true

      # First, create the application and attachments in a transaction
      application_created = ActiveRecord::Base.transaction do
        return failure('Constituent processing failed') unless process_constituent
        return failure('Application creation failed') unless create_application
        return failure('Proof upload failed') unless @skip_proof_processing || process_proof_uploads

        @application.persisted?
      end

      # If application was successfully created, send notifications outside the transaction
      if application_created && @application.persisted?
        begin
          handle_successful_application(:create)
        rescue StandardError => e
          # Log notification errors but don't fail the entire operation
          log_error(e, 'Failed to send notifications after successful application creation')
          # Application creation was successful, notifications failed but that's not critical
        end
      end

      application_created
    rescue StandardError => e
      log_error(e, 'Failed to create paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    def update(application)
      Current.paper_context = true

      ActiveRecord::Base.transaction do
        @application = application
        @constituent = application.user

        # Update application attributes if provided
        return failure('Application update failed') unless update_application_attributes

        # Process proof uploads (accept/reject)
        return failure('Proof upload failed') unless process_proof_uploads

        handle_successful_application(:update) if @application.persisted?
        return true
      end
    rescue StandardError => e
      log_error(e, 'Failed to update paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    ADULT_CONTACT_FIELDS = %i[
      email phone phone_type physical_address_1 physical_address_2
      city state zip_code communication_preference locale
      preferred_means_of_communication referral_source
    ].freeze

    private

    def failure(message)
      @errors << message
      false
    end

    def handle_successful_application(operation = :create)
      send_notifications
      case operation
      when :create
        log_application_creation
      when :update
        log_application_update
      end
    end

    def log_application_creation
      AuditEventService.log(
        action: 'application_created',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          initial_status: (@application.status || 'in_progress').to_s
        }
      )
    end

    def log_application_update
      AuditEventService.log(
        action: 'application_updated',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          updated_attributes: @application.saved_changes.keys,
          proof_actions: {
            income: params[:income_proof_action],
            residency: params[:residency_proof_action]
          }.compact
        }
      )
    end

    def process_constituent
      guardian_id = params[:guardian_id]
      new_guardian_attrs = params[:new_guardian_attributes]
      applicant_data = params[:constituent]
      relationship_type = params[:relationship_type]
      dependent_id = params[:dependent_id]
      existing_constituent_id = params[:existing_constituent_id]

      if existing_self_applicant_scenario?(existing_constituent_id)
        process_existing_self_applicant(existing_constituent_id)
      elsif existing_dependent_scenario?(guardian_id, dependent_id)
        process_existing_dependent(guardian_id, dependent_id, relationship_type)
      elsif guardian_scenario?(guardian_id, new_guardian_attrs, applicant_data)
        process_guardian_dependent(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
      elsif self_applicant_scenario?(applicant_data)
        process_self_applicant(applicant_data)
      else
        add_error('Sufficient constituent or guardian/dependent parameters missing.')
        false
      end
    end

    def existing_self_applicant_scenario?(existing_constituent_id)
      existing_constituent_id.present? && params[:applicant_type] != 'dependent'
    end

    def process_existing_self_applicant(existing_constituent_id)
      user = User.find_by(id: existing_constituent_id)
      return add_error('Applicant not found') unless user
      return add_error('Selected user is not eligible as an applicant.') unless user.paper_applicant_candidate?

      # Dual eligibility check
      return add_error('This constituent already has an active or pending application.') if user.applications.blocking_new_submission.exists?

      return false unless waiting_period_eligible?(user)

      return add_error('Verify contact information against the paper application before submitting.') unless existing_adult_contact_info_verified?

      @constituent = user

      if params[:constituent].present? && attributes_present?(params[:constituent]) &&
         existing_adult_contact_updates_allowed? && !update_existing_adult_contact_info(user)
        return false
      end

      true
    end

    def existing_adult_contact_info_verified?
      ActiveModel::Type::Boolean.new.cast(params.fetch(:contact_info_verified, false))
    end

    def existing_adult_contact_updates_allowed?
      params[:contact_info_mode].to_s != 'on_file'
    end

    def guardian_scenario?(guardian_id, new_guardian_attrs, applicant_data)
      (guardian_id.present? || attributes_present?(new_guardian_attrs)) &&
        attributes_present?(applicant_data) &&
        params[:applicant_type] == 'dependent'
    end

    def existing_dependent_scenario?(guardian_id, dependent_id)
      guardian_id.present? && dependent_id.present? && params[:applicant_type] == 'dependent'
    end

    def process_existing_dependent(guardian_id, dependent_id, relationship_type)
      guardian = User.find_by(id: guardian_id)
      dependent = User.find_by(id: dependent_id)

      return add_error('Guardian not found') unless guardian
      return add_error('Dependent not found') unless dependent

      return false unless ensure_guardian_relationship(guardian, dependent, relationship_type)
      return false unless update_dependent_and_validate_eligibility(dependent)

      @guardian_user_for_app = guardian
      @constituent = dependent
      true
    end

    def ensure_guardian_relationship(guardian, dependent, relationship_type)
      rel = GuardianRelationship.find_by(guardian_id: guardian.id, dependent_id: dependent.id)
      return true if rel.present?

      return add_error('Relationship type required to relate guardian and dependent') if relationship_type.blank?

      begin
        GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent, relationship_type: relationship_type)
        true
      rescue ActiveRecord::RecordInvalid => e
        add_error("Failed to create relationship: #{e.record.errors.full_messages.join(', ')}")
        false
      end
    end

    def update_dependent_and_validate_eligibility(dependent)
      # Update dependent information if provided (contact info may have changed)
      return false if params[:constituent].present? && attributes_present?(params[:constituent]) && !update_dependent_contact_info(dependent)

      # Validate no active application for dependent
      return add_error('This dependent already has an active or pending application.') if Application.where(user_id: dependent.id).blocking_new_submission.exists?

      waiting_period_eligible?(dependent)
    end

    def waiting_period_eligible?(user)
      last_app = user.applications.order(application_date: :desc).first
      return true if last_app.blank?

      waiting_period = Policy.get('waiting_period_years') || 3
      eligible_date = last_app.application_date + waiting_period.years
      return true if eligible_date <= Time.current

      add_error("Not yet eligible for a new application. Eligible after #{eligible_date.to_date.strftime('%B %d, %Y')}.")
      false
    end

    def self_applicant_scenario?(applicant_data)
      attributes_present?(applicant_data) && params[:applicant_type] != 'dependent'
    end

    def process_guardian_dependent(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
      service = GuardianDependentManagementService.new(params)
      result = service.process_guardian_scenario(guardian_id, new_guardian_attrs, applicant_data, relationship_type)

      if result.success?
        @guardian_user_for_app = result.data[:guardian]
        @constituent = result.data[:dependent]

        # Store temp passwords if created
        store_temp_password(@guardian_user_for_app) if @guardian_user_for_app
        store_temp_password(@constituent) if @constituent

        validate_no_active_application('dependent')
      else
        @errors.concat(service.errors)
        false
      end
    end

    def process_self_applicant(applicant_data)
      result = UserCreationService.new(applicant_data, is_managing_adult: true).call

      if result.success?
        @constituent = result.data[:user]
        store_temp_password(@constituent, result.data[:temp_password])
        validate_no_active_application('constituent')
      else
        @errors.concat(result.data[:errors] || [result.message])
        false
      end
    end

    def store_temp_password(user, password = nil)
      return unless user && password

      @temp_passwords[user.id] = password
    end

    def validate_no_active_application(user_type)
      return true unless @constituent.applications.blocking_new_submission.exists?

      error_message = case user_type
                      when 'dependent'
                        'This dependent already has an active or pending application.'
                      else
                        'This constituent already has an active or pending application.'
                      end
      add_error(error_message)
      false
    end

    def update_dependent_contact_info(dependent)
      attrs = params[:constituent]
      return true if attrs.blank?

      updates = build_dependent_contact_updates(attrs)
      return true if updates.empty?

      if dependent.update(updates)
        Rails.logger.info "Updated contact info for dependent #{dependent.id}: #{updates.keys.join(', ')}"
        true
      else
        add_error("Failed to update dependent information: #{dependent.errors.full_messages.join(', ')}")
        false
      end
    rescue ActiveRecord::RecordInvalid => e
      add_error("Failed to update dependent information: #{e.record.errors.full_messages.join(', ')}")
      false
    end

    def build_dependent_contact_updates(attrs)
      build_contact_updates(
        attrs,
        fields: %i[
          physical_address_1 physical_address_2 city state zip_code
          locale communication_preference preferred_means_of_communication
          phone_type referral_source
        ],
        aliases: { dependent_email: :email, dependent_phone: :phone }
      )
    end

    def update_existing_adult_contact_info(user)
      attrs = params[:constituent]
      return true if attrs.blank?

      updates = build_adult_contact_updates(attrs)
      return true if updates.empty?

      changed_fields = updates.each_with_object({}) do |(key, new_val), changes|
        old_val = user.read_attribute(key)
        changes[key] = { from: old_val, to: new_val } if old_val.to_s != new_val.to_s
      end

      return true if changed_fields.empty?

      if user.update(updates)
        AuditEventService.log(
          action: 'constituent_contact_updated',
          actor: @admin,
          auditable: user,
          metadata: {
            source: 'paper_application',
            changes: changed_fields
          }
        )
        true
      else
        add_error("Failed to update applicant information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def build_adult_contact_updates(attrs)
      build_contact_updates(attrs, fields: ADULT_CONTACT_FIELDS)
    end

    def build_contact_updates(attrs, fields:, aliases: {})
      updates = {}
      fields.each { |f| updates[f] = attrs[f] if attrs[f].present? }
      aliases.each { |src, dest| updates[dest] = attrs[src] if attrs[src].present? }
      updates
    end

    def create_application
      Current.paper_context = true

      application_attrs = params[:application]
      return add_error('Application params missing') if application_attrs.blank?

      return false unless validate_income_threshold(application_attrs)

      @constituent.reload
      build_and_save_application(application_attrs)
    ensure
      Current.paper_context = nil
    end

    def validate_income_threshold(application_attrs)
      # Skip validation if explicitly requested (e.g., for rejection cases)
      return true if @skip_income_validation

      household_size = application_attrs[:household_size]
      annual_income = application_attrs[:annual_income]

      threshold_service = IncomeThresholdCalculationService.new(household_size)
      result = threshold_service.call

      return false unless result.success?

      threshold = result.data[:threshold]
      return true if annual_income.to_i <= threshold

      add_error('Income exceeds the maximum threshold for the household size.')
      false
    end

    def build_and_save_application(application_attrs)
      @application = Application.new(application_attrs)
      @application.user = @constituent
      @application.managing_guardian = @guardian_user_for_app
      @application.submission_method = :paper
      @application.application_date = Time.current

      # Set appropriate status based on what's missing
      @application.status = determine_initial_status

      return true if @application.save

      add_error("Failed to create application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def determine_initial_status
      # awaiting_proof if:
      # 1. No medical provider info provided
      # 2. No proofs provided (income_proof_action: 'none' or residency_proof_action: 'none')
      # 3. Proofs were rejected (income_proof_action: 'reject' or residency_proof_action: 'reject')

      return :awaiting_proof if params[:no_medical_provider_information]

      income_action = params[:income_proof_action]
      residency_action = params[:residency_proof_action]

      # If no proofs provided or any proofs rejected, awaiting proof
      return :awaiting_proof if income_action.in?(%w[none reject]) || residency_action.in?(%w[none reject])

      # Otherwise, in progress (has all initial documentation)
      :in_progress
    end

    # Update application attributes within paper context
    # only if params[:application] is present
    def update_application_attributes
      application_attrs = params[:application]
      return true if application_attrs.blank?

      # Update attributes - model callback automatically sets paper context
      return true if @application.update(application_attrs)

      add_error("Failed to update application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def process_proof_uploads
      Current.paper_context = true

      %i[income residency medical_certification].each do |proof_type|
        return false unless process_proof(proof_type)
      end

      true
    ensure
      Current.paper_context = nil
    end

    def process_proof(type)
      # Handle medical_certification naming convention
      action_key = type == :medical_certification ? "#{type}_action" : "#{type}_proof_action"
      action = params[action_key] || params[action_key.to_sym]

      return true unless %w[accept reject approved rejected not_requested].include?(action)

      case action
      when 'accept', 'approved'
        process_accept_proof(type)
      when 'reject', 'rejected'
        process_reject_proof(type)
      when 'not_requested'
        true
      end
    end

    def process_accept_proof(type)
      # Handle medical_certification naming convention
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"

      file_param = params[file_key]
      signed_id_param = params[signed_id_key]

      # Check if we have a valid file or signed_id
      # file_param can be:
      # - An uploaded file (ActionDispatch::Http::UploadedFile)
      # - A file-like object (responds to :read)
      # - A signed blob ID string (String)
      # signed_id_param should be a non-empty string if present
      file_valid = file_param.present? && (
        file_param.respond_to?(:read) ||
        file_param.is_a?(ActionDispatch::Http::UploadedFile) ||
        (file_param.is_a?(String) && !file_param.empty?)
      )
      signed_id_valid = signed_id_param.present? && signed_id_param.is_a?(String) && !signed_id_param.empty?

      file_present = file_valid || signed_id_valid

      # Approval requires an attachment in all contexts. Only rejections may proceed without files.
      return add_error("Please upload a file for #{type} proof before approving") unless file_present

      attach_and_approve_proof(type)
    end

    def attach_and_approve_proof(type)
      # Handle medical_certification naming convention
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"

      blob_or_file = params[file_key].presence || params[signed_id_key].presence

      # Route medical certifications to the correct service
      result = if type == :medical_certification
                 MedicalCertificationAttachmentService.attach_certification(
                   application: @application,
                   blob_or_file: blob_or_file,
                   status: :approved,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               else
                 ProofAttachmentService.attach_proof(
                   application: @application,
                   proof_type: type,
                   blob_or_file: blob_or_file,
                   status: :approved,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               end

      unless result[:success]
        add_error("Error processing #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
    end

    def process_reject_proof(type)
      reason_key        = type == :medical_certification ? "#{type}_rejection_reason" : "#{type}_proof_rejection_reason"
      custom_reason_key = type == :medical_certification ? "#{type}_custom_rejection_reason" : "#{type}_proof_custom_rejection_reason"
      notes_key         = type == :medical_certification ? "#{type}_rejection_notes" : "#{type}_proof_rejection_notes"
      selected_reason   = fetch_param(reason_key).to_s
      custom_reason     = fetch_param(custom_reason_key).to_s.strip
      legacy_notes      = fetch_param(notes_key).to_s.strip
      custom_reason     = legacy_notes if custom_reason.blank? && legacy_notes.present?

      result = if type == :medical_certification
                 reject_medical_certification(
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               else
                 reject_non_medical_proof(
                   type: type,
                   selected_reason: selected_reason,
                   custom_reason: custom_reason,
                   notes: legacy_notes.presence
                 )
               end

      unless result[:success]
        add_error("Error rejecting #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
    end

    def resolve_rejection_reason_value(selected_reason:, custom_reason:)
      return selected_reason unless selected_reason == 'other'
      return 'Other' if custom_reason.blank?

      custom_reason
    end

    def reject_non_medical_proof(type:, selected_reason:, custom_reason:, notes:)
      resolved_reason = resolve_rejection_reason_value(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      ProofAttachmentService.reject_proof_without_attachment(
        application: @application,
        proof_type: type,
        admin: @admin,
        reason: resolved_reason,
        notes: notes,
        submission_method: :paper,
        metadata: {}
      )
    end

    def resolve_medical_rejection_reason_payload(selected_reason:, custom_reason:)
      if selected_reason.present? && %w[none_provided other].exclude?(selected_reason)
        resolved_reason = RejectionReason.resolve_text(
          code: selected_reason,
          proof_type: 'medical_certification',
          fallback: selected_reason
        )

        return { reason: resolved_reason, reason_code: selected_reason }
      end

      return { reason: 'none_provided', reason_code: nil } if selected_reason == 'none_provided'
      return { reason: 'Other', reason_code: nil } if custom_reason.blank?

      { reason: custom_reason, reason_code: nil }
    end

    def fetch_param(key)
      params[key] || params[key.to_sym]
    end

    def reject_medical_certification(selected_reason:, custom_reason:, notes:)
      if medical_certification_reviewer_path?(selected_reason)
        reject_medical_certification_via_reviewer(
          selected_reason: selected_reason,
          custom_reason: custom_reason,
          notes: notes
        )
      else
        reject_medical_certification_directly(
          selected_reason: selected_reason,
          custom_reason: custom_reason,
          notes: notes
        )
      end
    end

    def medical_certification_reviewer_path?(selected_reason)
      selected_reason != 'none_provided' && medical_provider_notification_available?
    end

    def medical_provider_notification_available?
      @application.medical_provider_name.present? &&
        (@application.medical_provider_email.present? || @application.medical_provider_fax.present?)
    end

    def reject_medical_certification_via_reviewer(selected_reason:, custom_reason:, notes:)
      reason_payload = resolve_medical_rejection_reason_payload(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      reviewer_result = Applications::MedicalCertificationReviewer.new(@application, @admin).reject(
        rejection_reason: reason_payload[:reason],
        notes: notes,
        rejection_reason_code: reason_payload[:reason_code]
      )

      return { success: true } if reviewer_result.success?

      { success: false, error: StandardError.new(reviewer_result.message) }
    end

    def reject_medical_certification_directly(selected_reason:, custom_reason:, notes:)
      reason_payload = resolve_medical_rejection_reason_payload(
        selected_reason: selected_reason,
        custom_reason: custom_reason
      )

      MedicalCertificationAttachmentService.reject_certification(
        application: @application,
        admin: @admin,
        reason: reason_payload[:reason],
        notes: notes,
        reason_code: reason_payload[:reason_code],
        submission_method: :paper,
        metadata: {}
      )
    end

    def log_proof_submission(type, has_attachment)
      AuditEventService.log(
        action: 'proof_submitted',
        actor: @admin,
        auditable: @application,
        metadata: {
          proof_type: type.to_s,
          submission_method: 'paper',
          status: 'approved',
          has_attachment: has_attachment
        }
      )
    end

    def send_notifications
      send_proof_rejection_notifications
      send_account_creation_notifications
    end

    def send_proof_rejection_notifications
      @application.proof_reviews.reload.each do |review|
        next unless review.status_rejected?

        if review.proof_type == 'medical_certification' && review.rejection_reason_code == 'none_provided'
          NotificationService.create_and_deliver!(
            type: 'medical_certification_not_provided',
            recipient: @constituent,
            actor: @admin,
            notifiable: @application,
            channel: @constituent.communication_preference.to_sym
          )
          next
        end

        NotificationService.create_and_deliver!(
          type: 'proof_rejected',
          recipient: @constituent,
          actor: @admin,
          notifiable: review,
          metadata: {
            template_variables: proof_rejection_template_variables(review)
          },
          channel: @constituent.communication_preference.to_sym
        )
      end
    end

    def send_account_creation_notifications
      new_user_accounts.each do |user|
        temp_password = @temp_passwords[user.id]
        next unless temp_password

        ensure_user_password(user, temp_password)

        NotificationService.create_and_deliver!(
          type: 'account_created',
          recipient: user,
          actor: @admin,
          notifiable: @application,
          metadata: {
            temp_password: temp_password,
            template_variables: account_creation_template_variables(user, temp_password)
          },
          channel: user.communication_preference.to_sym
        )
      end
    end

    def new_user_accounts
      [@guardian_user_for_app, @constituent].compact.uniq.select do |user|
        user.present? && user.created_at >= 5.minutes.ago && @temp_passwords.key?(user.id)
      end
    end

    def ensure_user_password(user, temp_password)
      return if user.password_digest.present?

      user.update(password: temp_password, password_confirmation: temp_password)
    end

    def account_creation_template_variables(user, temp_password)
      {
        constituent_first_name: user.first_name,
        constituent_email: user.email,
        temp_password: temp_password,
        sign_in_url: sign_in_url(host: Rails.application.config.action_mailer.default_url_options[:host])
      }
    end

    def proof_rejection_template_variables(review)
      {
        constituent_full_name: @constituent.full_name,
        organization_name: Policy.get('organization_name') || 'MAT Program',
        proof_type_formatted: review.proof_type.humanize,
        rejection_reason: review.rejection_reason || 'Document did not meet requirements'
      }
    end

    def attributes_present?(attrs)
      attrs.present? && attrs.values.any?(&:present?)
    end

    def add_error(message)
      @errors << message
      false
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n") if exception.backtrace
    end
  end
end
