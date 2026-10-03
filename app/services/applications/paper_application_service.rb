# frozen_string_literal: true

module Applications
  # Paper intake uses the shared attachment services for portal and admin uploads.
  # rubocop:disable Metrics/ClassLength
  class PaperApplicationService < BaseService
    include Rails.application.routes.url_helpers

    class TransactionFailure < StandardError; end

    # The exception carries staff guidance for failed results and exceptions into the named warning and audit event.
    class PostCreationStepFailure < StandardError; end

    # This step name distinguishes callback failures from later follow-up failures.
    # Do not retry a failed callback. It may already have completed some side effects.
    POST_COMMIT_CALLBACK_STEP = 'a post-commit callback'

    attr_reader :params, :admin, :application, :constituent, :errors, :guardian_user_for_app, :reconciliation_note,
                :identity_review, :warnings

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
      @warnings = []
      @commit_confirmed = true
      @identity_review = nil
      @skip_income_validation = skip_income_validation
      @skip_proof_processing = skip_proof_processing
    end

    def create
      Current.paper_context = true
      application_created = run_create_transaction

      # Skip record-dependent work when commit verification fails.
      # Another database error could report a committed application as a failure and invite a duplicate submission.
      if application_created && commit_confirmed?
        begin
          handle_successful_application(:create)
        rescue StandardError => e
          # Surface an unexpected failure because it can skip later follow-up steps.
          log_error(e, 'Failed to finish post-creation steps after a successful application creation')
          add_warning('The application was created, but a follow-up step did not finish. ' \
                      'Review this application before treating it as complete.')
        end

        # Reconcile after commit so a reconciliation failure cannot roll back proof writes.
        # The warning tells staff to verify the status and advance it manually if needed.
        reconcile_after_paper_write(:paper_application_created)
      end

      application_created
    rescue GuardianDependentManagementService::DependentCreationConflict
      recover_dependent_creation_conflict
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

    # Keep reconciliation guidance and other follow-up warnings together so neither is lost.
    def warning_message
      [@reconciliation_note, *@warnings].compact_blank.join(' ').presence
    end

    # An unverified write must not route to the application page. The row may not exist.
    def commit_confirmed?
      @commit_confirmed
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

    # An after_commit exception can escape after the data commits. Verify durable existence before reporting failure.
    # Use the database instead of the in-memory persisted? value to distinguish commit from rollback.
    # Do not retry a failed callback. Its completed side effects could repeat.
    def run_create_transaction
      ActiveRecord::Base.transaction do
        rollback_failure_unless_explained('Constituent processing failed') unless process_constituent
        rollback_failure('Application creation failed') unless create_application
        rollback_failure_unless_explained('Proof upload failed') unless @skip_proof_processing || process_proof_uploads
        record_identity_decision!

        @application.persisted?
      end
    rescue TransactionFailure
      raise
    rescue StandardError => e
      state = commit_state
      # Only a confirmed rollback permits a retry form.
      raise if state == :rolled_back

      log_error(e, 'Paper application post-commit step failed')
      # An unknown commit routes to the list because the application page may return 404.
      @commit_confirmed = (state == :committed)
      add_warning(post_commit_warning_for(state))
      # Record unfinished work durably after a confirmed commit.
      # An unknown commit may have no application row, and another database query could fail.
      record_incomplete_follow_up(POST_COMMIT_CALLBACK_STEP, e) if @commit_confirmed
      true
    end

    def post_commit_warning_for(state)
      if state == :unknown
        'The application may have been created, but that could not be confirmed. Check the ' \
          'applications list before entering it again -- submitting again could create a duplicate.'
      else
        'The application was created, but a follow-up step did not finish. ' \
          'Review this application before treating it as complete.'
      end
    end

    # Keep an unknown commit distinct from rollback to prevent duplicate submissions.
    # This query uses the writer connection. No reader role is configured.
    # If a reader role is added, keep this query on the writer to avoid stale results from replica lag.

    # @return [Symbol] :committed, :rolled_back, or :unknown
    def commit_state
      id = @application&.id
      return :rolled_back if id.blank?

      Application.exists?(id) ? :committed : :rolled_back
    rescue StandardError => e
      log_error(e, 'Could not confirm whether the paper application committed')
      :unknown
    end

    def add_warning(message)
      @warnings << message unless @warnings.include?(message)
    end

    def failure(message)
      @errors << message
      false
    end

    def rollback_failure(message)
      failure(message)
      raise TransactionFailure, message
    end

    # Preserve a specific error without a redundant internal step name.
    def rollback_failure_unless_explained(message)
      failure(message) if @errors.empty?
      raise TransactionFailure, message
    end

    # Record creation before notifications so a delivery failure cannot skip the creation event.
    # Isolate each step, including the audit write, so one failure does not cancel the others.
    # Production paper intake calls create. The update path retains its separate behavior.
    def handle_successful_application(operation = :create)
      case operation
      when :create then run_post_creation_step('the creation audit event') { log_application_creation }
      when :update
        log_application_update
      end

      run_post_creation_step('notifications') { send_notifications }
      run_post_creation_step('proof delivery checks') { append_proof_resubmission_delivery_warnings }
      run_post_creation_step('the certifying provider request') { request_provider_info_if_missing } if operation == :create
    end

    def run_post_creation_step(description)
      yield
    rescue StandardError => e
      # The wrapper carries staff guidance. Its cause supplies the original error and backtrace for the log and audit
      # event.
      diagnostic = e.cause || e
      log_error(diagnostic, "Paper application post-creation step failed: #{description}")
      detail = e.is_a?(PostCreationStepFailure) ? "#{e.message} " : ''
      add_warning("The application was created, but #{description} did not finish. #{detail}" \
                  'Review this application before treating it as complete.')
      record_incomplete_follow_up(description, diagnostic)
    end

    # Record unfinished work beyond the flash message.
    # If this audit write fails, log the error without reporting the committed application as a failure.
    def record_incomplete_follow_up(description, error)
      AuditEventService.log(
        action: 'application_post_creation_step_failed',
        actor: @admin,
        auditable: @application,
        metadata: {
          submission_method: 'paper',
          step: description,
          error_class: error.class.name
        }
      )
    rescue StandardError => e
      log_error(e, 'Could not record the incomplete paper follow-up step')
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
      applicant_data = params[:constituent]
      relationship_type = params[:relationship_type]
      dependent_id = params[:dependent_id]
      existing_constituent_id = params[:existing_constituent_id]

      if params[:identity_candidate_id].present?
        process_reviewed_selection
      elsif existing_self_applicant_scenario?(existing_constituent_id)
        process_existing_self_applicant(existing_constituent_id)
      elsif existing_dependent_scenario?(guardian_id, dependent_id)
        process_existing_dependent(guardian_id, dependent_id, relationship_type)
      elsif guardian_scenario?(guardian_id, applicant_data)
        process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      elsif self_applicant_scenario?(applicant_data)
        process_self_applicant(applicant_data)
      elsif dependent_with_unsaved_guardian?(applicant_data)
        add_error('Save or select the guardian before submitting the paper application.')
      else
        add_error('Sufficient constituent or guardian/dependent parameters missing.')
        false
      end
    end

    def existing_self_applicant_scenario?(existing_constituent_id)
      existing_constituent_id.present? && params[:applicant_type] != 'dependent'
    end

    def process_existing_self_applicant(existing_constituent_id)
      user = User.lock.find_by(id: existing_constituent_id)
      return add_error('Applicant not found') unless user
      return add_error('Selected user is not eligible as an applicant.') unless user.paper_applicant_candidate?

      return false unless paper_application_eligible?(user, subject: :constituent)

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

    def guardian_scenario?(guardian_id, applicant_data)
      guardian_id.present? && attributes_present?(applicant_data) &&
        params[:applicant_type] == 'dependent'
    end

    def existing_dependent_scenario?(guardian_id, dependent_id)
      guardian_id.present? && dependent_id.present? && params[:applicant_type] == 'dependent'
    end

    def process_existing_dependent(guardian_id, dependent_id, _relationship_type)
      locked_users = User.lock.where(id: [guardian_id, dependent_id]).order(:id).index_by { |user| user.id.to_s }
      guardian = locked_users[guardian_id.to_s]
      dependent = locked_users[dependent_id.to_s]

      return add_error('Guardian not found') unless guardian
      return add_error('Dependent not found') unless dependent
      return add_error('Selected guardian is not an eligible active constituent.') unless guardian.paper_guardian_candidate?
      return add_error('Selected dependent is not an eligible constituent.') unless dependent.paper_dependent_candidate?

      return false unless ensure_guardian_relationship(guardian, dependent)
      return false unless update_dependent_and_validate_eligibility(dependent)

      @guardian_user_for_app = guardian
      @constituent = dependent
      true
    end

    def ensure_guardian_relationship(guardian, dependent)
      rel = GuardianRelationship.lock.find_by(guardian_id: guardian.id, dependent_id: dependent.id)
      return true if rel.present?

      add_error('The selected dependent is not on file for this guardian. Choose an on-file dependent or contact MAT support.')
    end

    def update_dependent_and_validate_eligibility(dependent)
      return false unless paper_application_eligible?(dependent, subject: :dependent)

      return false unless update_existing_applicant_disability_info(dependent)

      return false if params[:constituent].present? && attributes_present?(params[:constituent]) && !update_dependent_contact_info(dependent)

      true
    end

    def self_applicant_scenario?(applicant_data)
      attributes_present?(applicant_data) && params[:applicant_type] != 'dependent'
    end

    def dependent_with_unsaved_guardian?(applicant_data)
      params[:applicant_type] == 'dependent' &&
        (ActiveModel::Type::Boolean.new.cast(params[:unsaved_guardian_present]) ||
         attributes_present?(applicant_data) || attributes_present?(params[:guardian_attributes]))
    end

    def process_guardian_dependent(guardian_id, applicant_data, relationship_type)
      service = GuardianDependentManagementService.new(params, actor: @admin)
      result = service.process_guardian_scenario(guardian_id, applicant_data, relationship_type)
      @identity_review = service.identity_review

      if result.success?
        @guardian_user_for_app = result.data[:guardian]
        @constituent = result.data[:dependent]

        track_email_backed_portal_created_user_ids(result.data[:email_backed_portal_created_user_ids])

        paper_application_eligible?(@constituent, subject: :dependent)
      else
        @errors.concat(service.errors)
        false
      end
    end

    # PostgreSQL rejects queries after a unique-index violation until rollback.
    # Recompute identity review after the outer transaction rolls back. Do not retry the write.
    def recover_dependent_creation_conflict
      Rails.logger.warn('Dependent creation hit a unique constraint; identity review recomputed after rollback')
      guardian = User.find_by(id: params[:guardian_id])
      review = if guardian&.paper_guardian_candidate?
                 Applications::PaperIdentityReview.new(
                   constituent_params: params[:constituent],
                   contact_flag_params: params,
                   admin: @admin,
                   submitted_token: nil,
                   context: :dependent,
                   context_data: { guardian: guardian, relationship_type: params[:relationship_type] }
                 ).call
               end

      if review&.blocked?
        add_error(GuardianDependentManagementService::DEPENDENT_CONTACT_COLLISION_MESSAGE)
      else
        add_error('Dependent contact information changed while saving. ' \
                  'Review the dependent before trying again.')
      end
    rescue StandardError => e
      log_error(e, 'Could not classify a dependent creation conflict after rollback')
      add_error('Dependent contact information changed while saving. ' \
                'Review the dependent before trying again.')
    end

    def process_self_applicant(applicant_data)
      contact_flags = paper_contact_flags(:constituent)
      @identity_review = review_paper_identity(applicant_data)
      return false unless identity_review_permits_creation?(@identity_review)

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
        track_email_backed_portal_created_user_id(result.data[:email_backed_portal_created_user_id])

        return false unless paper_application_eligible?(@constituent, subject: :constituent)

        true
      else
        @errors.concat(result.data[:errors] || [result.message])
        false
      end
    end

    # Recompute identity review under the creation lock.
    def review_paper_identity(applicant_data)
      review = Applications::PaperIdentityReview.new(
        constituent_params: applicant_data,
        admin: @admin,
        contact_flag_params: params,
        submitted_token: params[:identity_review_receipt],
        determination: params[:identity_determination]
      )

      # Use the review facts for both the lock and the search.
      Applications::PaperIdentityCreationLock.lock!(review.identity_facts)
      review.call(lock: true)
    end

    # Only an explicit, freshly verified decision can override soft matches.
    def identity_review_permits_creation?(review)
      return add_error('Duplicate detection failed. Try again.') if review.error?
      return add_error('The applicant details or possible matches changed since you reviewed them. Review again.') if review.invalid_decision?

      if review.blocked?
        return add_error('An applicant with this email or phone already exists. ' \
                         'Select the existing applicant instead of creating a new one.')
      end

      # An override requires a rationale. A clear review has no staff decision to record.
      if review.confirmed?
        return add_error('Explain the identity decision before continuing.') if params[:identity_rationale].blank?

        return true
      end

      return true if review.clear?

      add_error(no_match_decision_error(review.decision_reason, review.candidates.size))
      false
    end

    def no_match_decision_error(reason, candidate_count)
      return 'This review expired. Search again before creating a new constituent.' if reason == :expired

      if reason == :mismatched
        return 'The applicant details or the possible matches changed since you reviewed them. ' \
               'Search again before creating a new constituent.'
      end

      "#{candidate_count} possible #{'match'.pluralize(candidate_count)} found. " \
        'Review them and either select the existing constituent or confirm this is a different person.'
    end

    # Commit the identity decision with the application and proofs.
    def record_identity_decision!
      return unless @identity_review

      DuplicateReviewCases::CreateService.record_paper_decision!(
        review: @identity_review, user: @constituent, actor: @admin,
        rationale: params[:identity_rationale], receipt: params[:identity_review_receipt], application: @application
      )
    end

    def process_reviewed_selection
      dependent = params[:applicant_type] == 'dependent'
      guardian = User.find_by(id: params[:guardian_id]) if dependent
      owner = PaperIdentityReview.new(
        constituent_params: params[:constituent], admin: @admin, contact_flag_params: params,
        submitted_token: params[:identity_review_receipt], selected_candidate_id: params[:identity_candidate_id],
        context: dependent ? :dependent : :self_applicant,
        context_data: { guardian: guardian, relationship_type: params[:relationship_type] }
      )
      PaperIdentityCreationLock.lock!(owner.identity_facts)
      @identity_review = owner.call(lock: true)
      return add_error('Review the current matches and select an eligible person.') unless @identity_review.selected?
      return add_error('Explain the identity decision before continuing.') if params[:identity_rationale].blank?

      if dependent
        process_existing_dependent(guardian&.id, @identity_review.selected_user.id, params[:relationship_type])
      else
        process_existing_self_applicant(@identity_review.selected_user.id)
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

    def track_email_backed_portal_created_user_ids(user_ids)
      Array(user_ids).each { |user_id| track_email_backed_portal_created_user_id(user_id) }
    end

    def track_email_backed_portal_created_user_id(user_id)
      @created_portal_user_ids << user_id.to_s if user_id.present?
    end

    def paper_application_eligible?(user, subject:)
      result = PaperApplicationEligibility.call(user)
      return true if result.eligible?

      add_error(result.refusal_message(subject: subject))
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

      choice = Applications::PaperDependentContactChoice.new(
        applicant_data: attrs,
        strategy_params: params,
        existing_dependent: dependent,
        guardian: guardian
      ).call
      unless choice.valid?
        add_error(choice.message)
        return nil
      end

      strategy_service = GuardianDependentManagementService.new(params)
      applied = strategy_service.apply_contact_strategies_for(guardian, choice.resolved_applicant_data)
      if applied
        applied
      else
        @errors.concat(strategy_service.errors)
        nil
      end
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

      @application.status = determine_initial_status

      return true if @application.save

      add_error("Failed to create application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def determine_initial_status
      return :awaiting_proof if params[:no_medical_provider_information]

      income_action = params[:income_proof_action]
      residency_action = params[:residency_proof_action]

      if FeatureFlag.income_proof_required?
        return :awaiting_proof if income_action.in?(%w[none reject]) || residency_action.in?(%w[none reject])
      elsif residency_action.in?(%w[none reject])
        return :awaiting_proof
      end

      :in_progress
    end

    def update_application_attributes
      application_attrs = params[:application]
      return true if application_attrs.blank?

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
      blob_or_file = proof_upload(type)
      return false if blob_or_file == false

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
      file_key = type == :medical_certification ? type.to_s : "#{type}_proof"
      signed_id_key = type == :medical_certification ? "#{type}_signed_id" : "#{type}_proof_signed_id"

      file_param = params[file_key]
      signed_id_param = params[signed_id_key]

      # The file parameter also accepts a signed blob ID. UploadedDocument resolves and validates that ID before
      # attachment.
      file_valid = file_param.present? && (
        file_param.respond_to?(:read) ||
        file_param.is_a?(ActionDispatch::Http::UploadedFile) ||
        (file_param.is_a?(String) && !file_param.empty?)
      )
      signed_id_valid = signed_id_param.present? && signed_id_param.is_a?(String) && !signed_id_param.empty?

      file_present = file_valid || signed_id_valid

      # Paper approval requires a file. A rejection can proceed without one.
      return add_error("Please upload a file for #{type} proof before approving") unless file_present

      attach_and_approve_proof(type)
    end

    def attach_and_approve_proof(type)
      blob_or_file = proof_upload(type)
      return false if blob_or_file == false

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

    def proof_upload(type)
      key = type == :medical_certification ? type.to_s : "#{type}_proof"
      upload = params[key].presence || params["#{key}_signed_id"].presence
      return upload unless upload.is_a?(String)

      UploadedDocument.resolve!(upload, record: @application, name: key, max_bytes: paper_upload_max_bytes(type))
    rescue UploadedDocument::Refused => e
      add_error(paper_upload_refusal(type, e.reason))
    end

    # Certification limits remain separate from the shared size policy for other proofs.
    def paper_upload_max_bytes(type)
      ProofUploadFormats::PROOF_MAX_BYTES unless type == :medical_certification
    end

    def paper_upload_refusal(type, reason)
      label = proof_upload_label(type)
      case reason
      when :expired then "The uploaded #{label} has expired. Upload it again."
      when :attached_elsewhere then "The uploaded #{label} is already attached elsewhere. Upload it again."
      when :too_large then "The uploaded #{label} is larger than #{ProofUploadFormats.proof_max_megabytes}MB. Upload a smaller file."
      when :invalid_type then "The uploaded #{label} is not a #{ProofUploadFormats::HUMAN_LABEL} file. Upload it again."
      else "The uploaded #{label} is no longer available. Upload it again."
      end
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

    # Request provider information after the application commits when staff mark it missing and certification is not
    # approved.
    # The wrapper surfaces failures with manual-send guidance and a durable event.
    def request_provider_info_if_missing
      return unless params[:no_medical_provider_information]
      return if @application.medical_certification_status_approved?

      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: @admin
      ).call

      return if result.success?

      raise PostCreationStepFailure,
            "It could not be sent automatically: #{result.message} You can send it from the application page."
    rescue PostCreationStepFailure
      raise
    rescue StandardError
      # Wrap the exception to preserve manual-send guidance. The wrapper logs and audits the original cause.
      raise PostCreationStepFailure,
            'It could not be sent automatically. You can send it from the application page.'
    end

    # ProofReview routes income, residency, and ID rejections through Applications::RequestProofResubmission.
    # Paper intake sends the medical-certification-not-provided notice directly because it has no resubmission form.
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
        next unless user.email_backed_public_portal_account?

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

    # Account-created notices and printed letters require vouchers.
    # Equipment applicants and certification signers use secure upload links instead of public portal accounts.
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
      return false unless user.email_backed_public_portal_account?
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
