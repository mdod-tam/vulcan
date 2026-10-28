# frozen_string_literal: true

module Applications
  # Owns the paper application transaction, durable outcome and follow-up sequence.
  class PaperApplicationService < BaseService
    class TransactionFailure < StandardError; end

    attr_reader :params, :admin, :application, :errors, :reconciliation_note, :warnings

    delegate :constituent, :guardian_user_for_app, :identity_review, to: :@applicant_intake

    def initialize(params:, admin:, skip_income_validation: false, skip_proof_processing: false,
                   quick_created_portal_user_ids: [])
      super()
      @params = params.with_indifferent_access
      @admin = admin
      @warnings = []
      @commit_confirmed = true
      @quick_created_portal_user_ids = quick_created_portal_user_ids.map(&:to_s)
      @skip_income_validation = skip_income_validation
      @skip_proof_processing = skip_proof_processing
      @applicant_intake = PaperApplicantIntake.new(params: @params, admin: admin, errors: errors)
    end

    def create
      application_created = run_create_transaction
      return application_created unless application_created && commit_confirmed?

      begin
        follow_up.call
      rescue StandardError => e
        log_error(e, 'Failed to finish post-creation steps after a successful application creation')
        add_warning('The application was created, but a follow-up step did not finish. ' \
                    'Review this application before treating it as complete.')
      ensure
        @reconciliation_note = @follow_up&.reconciliation_note
      end
      reconcile_after_paper_write(:paper_application_created)
      application_created
    rescue GuardianDependentManagementService::DependentCreationConflict
      @applicant_intake.recover_dependent_creation_conflict
    rescue TransactionFailure
      false
    rescue StandardError => e
      log_error(e, 'Failed to create paper application')
      @errors << e.message
      false
    end

    def warning_message
      [@reconciliation_note, *@warnings].compact_blank.join(' ').presence
    end

    def commit_confirmed?
      @commit_confirmed
    end

    private

    # Restore paper context before identity evidence, commit callbacks and follow-up.
    def run_create_transaction
      ActiveRecord::Base.transaction do
        Current.set(paper_context: true) do
          rollback_failure_unless_explained('Constituent processing failed') unless @applicant_intake.call
          rollback_failure('Application creation failed') unless create_application
          unless @skip_proof_processing || PaperDocumentDispositions.new(
            params: params, admin: admin, application: application, errors: errors, warnings: warnings
          ).call
            rollback_failure_unless_explained('Proof upload failed')
          end
        end
        @applicant_intake.record_identity_decision!(application)
        application.persisted?
      end
    rescue TransactionFailure
      raise
    rescue StandardError => e
      state = commit_state
      raise if state == :rolled_back

      log_error(e, 'Paper application post-commit step failed')
      @commit_confirmed = (state == :committed)
      add_warning(post_commit_warning_for(state))
      # A callback may have completed side effects; record failure without rerunning it.
      follow_up.record_incomplete_follow_up('a post-commit callback', e) if @commit_confirmed
      true
    end

    def follow_up
      @follow_up ||= PaperCreationFollowUp.new(
        application: application, admin: admin, params: params,
        constituent: constituent, guardian_user_for_app: guardian_user_for_app,
        created_portal_user_ids: @applicant_intake.created_portal_user_ids,
        quick_created_portal_user_ids: @quick_created_portal_user_ids, warnings: warnings
      )
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

    # Verify on the writer connection; unknown is not evidence of rollback.
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

    def rollback_failure(message)
      add_error(message)
      raise TransactionFailure, message
    end

    def rollback_failure_unless_explained(message)
      add_error(message) if @errors.empty?
      raise TransactionFailure, message
    end

    def create_application
      application_attrs = params[:application]
      return add_error('Application params missing') if application_attrs.blank?

      return false unless validate_income_threshold(application_attrs)

      constituent.reload
      build_and_save_application(application_attrs)
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
      @application.user = constituent
      @application.managing_guardian = guardian_user_for_app
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

    def reconcile_after_paper_write(trigger)
      @application.reload.reconcile_workflow_state!(actor: @admin, trigger: trigger)
    rescue StandardError => e
      log_error(e, "Workflow reconciliation failed after paper application #{@application&.id} #{trigger}")
      @reconciliation_note = 'Workflow status update failed -- please verify this application status and advance it manually if needed.'
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.class.name}"
    end
  end
end
