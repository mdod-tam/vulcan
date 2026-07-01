# frozen_string_literal: true

module Applications
  # This service handles paper application submissions by administrators
  # It follows the same patterns as ConstituentPortal for file uploads
  # rubocop:disable Metrics/ClassLength
  class PaperApplicationService < BaseService
    include Rails.application.routes.url_helpers

    class TransactionFailure < StandardError; end

    attr_reader :params, :admin, :application, :constituent, :errors, :guardian_user_for_app, :reconciliation_note

    def initialize(params:, admin:, skip_income_validation: false, skip_proof_processing: false,
                   quick_created_portal_user_ids: [])
      super()
      @params = params.with_indifferent_access
      @admin = admin
      @application = nil
      @constituent = nil
      @guardian_user_for_app = nil
      @errors = []
      @created_portal_user_ids = []
      @quick_created_portal_user_ids = quick_created_portal_user_ids.map(&:to_s)
      @reconciliation_note = nil
      @skip_income_validation = skip_income_validation
      @skip_proof_processing = skip_proof_processing
    end

    def create
      Current.paper_context = true
      application_created = false

      ActiveRecord::Base.transaction do
        rollback_failure('Constituent processing failed') unless process_constituent
        rollback_failure('Application creation failed') unless create_application
        rollback_failure('Proof upload failed') unless @skip_proof_processing || process_proof_uploads

        application_created = @application.persisted?
      end

      if application_created
        begin
          handle_successful_application(:create)
        rescue StandardError => e
          log_error(e, 'Failed to send notifications after successful application creation')
        end

        # Reconcile outside the transaction so proof writes are committed regardless of
        # reconciliation outcome. Failure here means the application is stuck at the wrong
        # status, and we surface that to the admin via reconciliation_note.
        reconcile_after_paper_write(:paper_application_created)
      end

      application_created
    rescue TransactionFailure
      false
    rescue StandardError => e
      log_error(e, 'Failed to create paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    def update(application)
      Current.paper_context = true
      update_succeeded = false

      ActiveRecord::Base.transaction do
        @application = application
        @constituent = application.user

        rollback_failure('Application update failed') unless update_application_attributes
        rollback_failure('Proof upload failed') unless process_proof_uploads

        update_succeeded = true
      end

      reconcile_after_paper_write(:paper_application_updated) if update_succeeded

      update_succeeded
    rescue TransactionFailure
      false
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
    APPLICANT_DISABILITY_FIELDS = %i[
      hearing_disability vision_disability speech_disability
      mobility_disability cognition_disability
    ].freeze

    private

    def failure(message)
      @errors << message
      false
    end

    def rollback_failure(message)
      failure(message)
      raise TransactionFailure, message
    end

    def handle_successful_application(operation = :create)
      send_notifications
      append_proof_resubmission_delivery_warnings
      case operation
      when :create
        log_application_creation
        request_provider_info_if_missing
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

      return false unless update_existing_applicant_disability_info(user)

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
      return false unless update_existing_applicant_disability_info(dependent)

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

        track_portal_eligible_created_user_ids(result.data[:portal_eligible_created_user_ids])

        validate_no_active_application('dependent')
      else
        @errors.concat(service.errors)
        false
      end
    end

    def process_self_applicant(applicant_data)
      contact_flags = paper_contact_flags(:constituent)
      applicant_data = contact_flags.apply_to(applicant_data)

      result = UserCreationService.new(
        applicant_data,
        is_managing_adult: true,
        skip_user_lookup: true,
        skip_email_validation: contact_flags.skip_email_validation?,
        skip_phone_validation: contact_flags.skip_phone_validation?
      ).call

      if result.success?
        @constituent = result.data[:user]
        track_portal_eligible_created_user_id(result.data[:portal_eligible_created_user_id])

        return false unless validate_no_active_application('constituent')
        return false unless waiting_period_eligible?(@constituent)

        true
      else
        @errors.concat(result.data[:errors] || [result.message])
        false
      end
    end

    def no_email_address?(scope = :constituent)
      paper_contact_flags(scope).no_email?
    end

    def no_phone_number?(scope = :constituent)
      paper_contact_flags(scope).no_phone?
    end

    def paper_contact_flags(scope)
      Applications::PaperContactFlags.new(params, scope: scope)
    end

    def track_portal_eligible_created_user_ids(user_ids)
      Array(user_ids).each { |user_id| track_portal_eligible_created_user_id(user_id) }
    end

    def track_portal_eligible_created_user_id(user_id)
      @created_portal_user_ids << user_id.to_s if user_id.present?
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

      attrs = apply_dependent_contact_strategies!(attrs, dependent: dependent)
      return false if attrs.nil?

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

    def update_existing_applicant_disability_info(user)
      attrs = params[:constituent]
      return true if attrs.blank?

      updates = build_disability_updates(attrs)
      return true if updates.empty?

      if user.update(updates)
        true
      else
        add_error("Failed to update applicant disability information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def build_disability_updates(attrs)
      APPLICANT_DISABILITY_FIELDS.each_with_object({}) do |field, updates|
        updates[field] = attrs[field] if attrs.key?(field)
      end
    end

    def build_dependent_contact_updates(attrs)
      data = attrs.with_indifferent_access
      updates = {}

      %i[email phone dependent_email dependent_phone].each do |field|
        updates[field] = data[field] if data.key?(field)
      end

      %i[
        physical_address_1 physical_address_2 city state zip_code
        locale communication_preference preferred_means_of_communication
        phone_type referral_source
      ].each do |field|
        updates[field] = data[field] if data[field].present?
      end

      updates
    end

    def apply_dependent_contact_strategies!(attrs, dependent: nil)
      guardian = guardian_for_dependent_contact_update
      return attrs.deep_dup if guardian.blank?

      strategy_service = GuardianDependentManagementService.new(params)
      merged = merge_existing_dependent_contact(attrs, dependent)
      applied = strategy_service.apply_contact_strategies_for(guardian, merged)
      if applied
        applied
      else
        @errors.concat(strategy_service.errors)
        nil
      end
    end

    def merge_existing_dependent_contact(attrs, dependent)
      data = attrs.deep_dup.with_indifferent_access
      return data unless dependent

      if data[:dependent_email].blank? && data[:email].blank?
        if dependent.dependent_email.present?
          data[:dependent_email] = dependent.dependent_email
        elsif dependent.real_email?
          data[:email] = dependent.email
          data[:dependent_email] = dependent.email
        end
      end

      if data[:dependent_phone].blank? && data[:phone].blank?
        if dependent.dependent_phone.present?
          data[:dependent_phone] = dependent.dependent_phone
        elsif dependent.real_phone?
          data[:phone] = dependent.phone
          data[:dependent_phone] = dependent.phone
        end
      end

      data
    end

    def guardian_for_dependent_contact_update
      @guardian_user_for_app || User.find_by(id: params[:guardian_id])
    end

    def update_existing_adult_contact_info(user)
      persist_adult_contact_updates!(user, params[:constituent])
    end

    def persist_adult_contact_updates!(user, constituent_attrs)
      return true if constituent_attrs.blank?

      flagged = paper_contact_flags(:constituent).apply_to(constituent_attrs)
      updates = build_adult_contact_updates(flagged)
      return true if updates.empty?

      changed_fields = contact_field_changes(user, updates)
      return true if changed_fields.empty?

      if user.update(updates)
        log_constituent_contact_updated!(user, changed_fields)
        true
      else
        add_error("Failed to update applicant information: #{user.errors.full_messages.join(', ')}")
        false
      end
    end

    def contact_field_changes(user, updates)
      updates.each_with_object({}) do |(key, new_val), changes|
        old_val = user.read_attribute(key)
        changes[key] = { from: old_val, to: new_val } if old_val.to_s != new_val.to_s
      end
    end

    def log_constituent_contact_updated!(user, changed_fields)
      AuditEventService.log(
        action: 'constituent_contact_updated',
        actor: @admin,
        auditable: user,
        metadata: {
          source: 'paper_application',
          changes: changed_fields
        }
      )
    end

    def build_adult_contact_updates(attrs)
      updates = build_contact_updates(attrs, fields: ADULT_CONTACT_FIELDS)
      paper_contact_flags(:constituent).apply_clear_flags_to(updates)
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
      return true if @skip_income_validation
      return true unless FeatureFlag.income_proof_required?
      return true unless income_proof_action_requires_income_validation?

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

    def income_proof_action_requires_income_validation?
      params[:income_proof_action].to_s.in?(%w[accept approved])
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
      return :awaiting_proof if params[:no_medical_provider_information]

      income_action = params[:income_proof_action]
      residency_action = params[:residency_proof_action]

      # Only consider income action when income collection is enabled
      if FeatureFlag.income_proof_required?
        return :awaiting_proof if income_action.in?(%w[none reject]) || residency_action.in?(%w[none reject])
      elsif residency_action.in?(%w[none reject])
        return :awaiting_proof
      end

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

    def reconcile_after_paper_write(trigger)
      @application.reload.reconcile_workflow_state!(actor: @admin, trigger: trigger)
    rescue StandardError => e
      log_error(e, "Workflow reconciliation failed after paper application #{@application&.id} #{trigger}")
      @reconciliation_note = 'Workflow status update failed -- please verify this application status and advance it manually if needed.'
    end

    def process_proof_uploads
      Current.paper_context = true

      proof_types = %i[income residency id medical_certification]
      proof_types -= %i[income] unless @application.income_proof_required?

      proof_types.each do |proof_type|
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

      return true unless %w[upload_only accept reject approved rejected not_requested].include?(action)

      case action
      when 'upload_only'
        process_upload_only_proof(type)
      when 'accept', 'approved'
        process_accept_proof(type)
      when 'reject', 'rejected'
        process_reject_proof(type)
      when 'not_requested'
        true
      end
    end

    def process_upload_only_proof(type)
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"
      blob_or_file = params[file_key].presence || params[signed_id_key].presence

      return add_error("Please upload a file for #{proof_upload_label(type)} before sending it for review") if blob_or_file.blank?

      result = if type == :medical_certification
                 MedicalCertificationAttachmentService.attach_certification(
                   application: @application,
                   blob_or_file: blob_or_file,
                   status: :received,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               else
                 ProofAttachmentService.attach_proof(
                   application: @application,
                   proof_type: type,
                   blob_or_file: blob_or_file,
                   status: :not_reviewed,
                   admin: @admin,
                   submission_method: :paper,
                   metadata: {}
                 )
               end

      unless result[:success]
        add_error("Error processing #{proof_upload_label(type)}: #{result[:error]&.message}")
        return false
      end

      true
    end

    def proof_upload_label(type)
      type == :medical_certification ? 'medical certification' : "#{type} proof"
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
      send_medical_certification_not_provided_notice
      send_account_creation_notifications
    end

    # Automatically sends a provider info secure form to the constituent/guardian
    # when an admin creates a paper application without certifying professional info.
    # Failure is non-blocking: the application is already saved; the admin can send
    # the form manually from the application show page if delivery fails.
    def request_provider_info_if_missing
      return unless params[:no_medical_provider_information]
      return if @application.medical_certification_status_approved?

      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: @admin
      ).call

      return if result.success?

      note = "Certifying professional info form could not be automatically sent: #{result.message} " \
             'You can send it from the application page.'
      @reconciliation_note = [@reconciliation_note, note].compact.join(' ')
    rescue StandardError => e
      log_error(e, "Failed to auto-send provider info secure form after paper app #{@application&.id}")
      @reconciliation_note = [
        @reconciliation_note,
        'Certifying professional info form delivery failed. You can send it manually from the application page.'
      ].compact.join(' ')
    end

    # Income/residency/id proof rejections are delivered through ProofReview ->
    # Applications::RequestProofResubmission, which owns the secure resubmission flow.
    # The only constituent-facing rejection notice still sent directly from paper intake
    # is the "medical certification not provided" notice, which has no resubmission form.
    def send_medical_certification_not_provided_notice
      not_provided = @application.proof_reviews.reload.rejections.find_by(
        proof_type: :medical_certification,
        rejection_reason_code: 'none_provided'
      )
      return unless not_provided

      NotificationService.create_and_deliver!(
        type: 'medical_certification_not_provided',
        recipient: @constituent,
        actor: @admin,
        notifiable: @application,
        channel: @constituent.communication_preference.to_sym
      )
    end

    def send_account_creation_notifications
      return unless send_account_created_notice?

      new_user_accounts.each do |user|
        next unless user.portal_access_eligible?

        append_account_access_warning(user) if quick_created_portal_user?(user)

        NotificationService.create_and_deliver!(
          type: 'account_created',
          recipient: user,
          actor: @admin,
          notifiable: @application,
          metadata: {
            template_variables: account_creation_template_variables(user)
          },
          channel: user.communication_preference.to_sym
        )
      end
    end

    # Account-created notices (and their printed letters) are voucher-only.
    # Equipment-scope applicants and cert signers should use secure temporary
    # form links for proof/cert uploads; announcing an account they cannot create
    # or log in to would be misleading.
    def send_account_created_notice?
      FeatureFlag.enabled?(:vouchers_enabled)
    end

    def append_proof_resubmission_delivery_warnings
      @application.proof_reviews.rejections
                  .where(proof_type: ProofReview::REVIEWABLE_PROOF_TYPES)
                  .find_each do |review|
        next if Applications::RequestProofResubmission.delivery_confirmed_for_review?(review)

        note = "#{review.proof_type.to_s.humanize} proof resubmission form could not be automatically sent. " \
               'You can send it from the application page.'
        @reconciliation_note = [@reconciliation_note, note].compact.join(' ')
      end
    end

    def append_account_access_warning(user)
      note = "No temporary portal password is retained for #{user.full_name}. " \
             'Use the existing account access link flow if they need help signing in.'
      @reconciliation_note = [@reconciliation_note, note].compact.join(' ')
    end

    def new_user_accounts
      [@guardian_user_for_app, @constituent].compact.uniq.select do |user|
        user.present? && account_created_notice_candidate?(user)
      end
    end

    def account_created_notice_candidate?(user)
      return false unless user.portal_access_eligible?
      return false unless account_access_instructions_deliverable?(user)

      @created_portal_user_ids.include?(user.id.to_s) || quick_created_portal_user?(user)
    end

    def account_access_instructions_deliverable?(user)
      user.real_email? || user.sms_capable_phone?
    end

    def quick_created_portal_user?(user)
      @quick_created_portal_user_ids.include?(user.id.to_s)
    end

    def account_creation_template_variables(user)
      {
        constituent_first_name: user.first_name,
        support_email: Policy.get('support_email') || 'mat.program1@maryland.gov',
        program_website_url: ProgramContact.website_url
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
  # rubocop:enable Metrics/ClassLength
end
