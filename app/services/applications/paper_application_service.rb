# frozen_string_literal: true

module Applications
  # This service handles paper application submissions by administrators
  # It follows the same patterns as ConstituentPortal for file uploads
  class PaperApplicationService < BaseService
    include Rails.application.routes.url_helpers

    attr_reader :params, :admin, :application, :constituent, :errors, :guardian_user_for_app

    def initialize(params:, admin:, skip_income_validation: false)
      super()
      @params = params.with_indifferent_access
      @admin = admin
      @application = nil
      @constituent = nil
      @guardian_user_for_app = nil
      @errors = []
      @temp_passwords = {}
      @skip_income_validation = skip_income_validation
    end

    def create
      Current.paper_context = true

      # First, create the application and attachments in a transaction
      application_created = ActiveRecord::Base.transaction do
        return failure('Constituent processing failed') unless process_constituent
        return failure('Application creation failed') unless create_application
        return failure('Proof upload failed') unless process_proof_uploads

        @application.persisted?
      end

      # If application was successfully created, send notifications outside the transaction
      if application_created && @application.persisted?
        begin
          handle_successful_application
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

        return failure('Proof upload failed') unless process_proof_uploads

        handle_successful_application if @application.persisted?
        return true
      end
    rescue StandardError => e
      log_error(e, 'Failed to update paper application')
      @errors << e.message
      false
    ensure
      Current.paper_context = nil
    end

    private

    def failure(message) # rubocop:disable Naming/PredicateMethod
      @errors << message
      false
    end

    def handle_successful_application
      send_notifications
      log_application_creation
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

    def process_constituent
      guardian_id = params[:guardian_id]
      new_guardian_attrs = params[:new_guardian_attributes]
      applicant_data = params[:constituent]
      relationship_type = params[:relationship_type]

      if guardian_scenario?(guardian_id, new_guardian_attrs, applicant_data)
        process_guardian_dependent(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
      elsif self_applicant_scenario?(applicant_data)
        process_self_applicant(applicant_data)
      else
        add_error('Sufficient constituent or guardian/dependent parameters missing.')
        false
      end
    end

    def guardian_scenario?(guardian_id, new_guardian_attrs, applicant_data)
      (guardian_id.present? || attributes_present?(new_guardian_attrs)) &&
        attributes_present?(applicant_data) &&
        params[:applicant_type] == 'dependent'
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

    def validate_no_active_application(user_type) # rubocop:disable Naming/PredicateMethod
      return true unless @constituent.applications.where.not(status: :archived).exists?

      error_message = case user_type
                      when 'dependent'
                        'This dependent already has an active or pending application.'
                      else
                        'This constituent already has an active or pending application.'
                      end
      add_error(error_message)
      false
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

    def validate_income_threshold(application_attrs) # rubocop:disable Naming/PredicateMethod
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

    def build_and_save_application(application_attrs) # rubocop:disable Naming/PredicateMethod
      @application = Application.new(application_attrs)
      @application.user = @constituent
      @application.managing_guardian = @guardian_user_for_app
      @application.submission_method = :paper
      @application.application_date = Time.current
      @application.status = :in_progress

      return true if @application.save

      add_error("Failed to create application: #{@application.errors.full_messages.join(', ')}")
      false
    end

    def process_proof_uploads
      Current.paper_context = true

      %i[income residency].each do |proof_type|
        return false unless process_proof(proof_type)
      end

      true
    ensure
      Current.paper_context = nil
    end

    def process_proof(type)
      action = params["#{type}_proof_action"] || params[:"#{type}_proof_action"]

      return true unless %w[accept reject].include?(action)

      case action
      when 'accept'
        process_accept_proof(type)
      when 'reject'
        process_reject_proof(type)
      end
    end

    def process_accept_proof(type)
      file_present = params["#{type}_proof"].present? || params["#{type}_proof_signed_id"].present?

      # Approval requires an attachment in all contexts. Only rejections may proceed without files.
      return add_error("Please upload a file for #{type} proof before approving") unless file_present

      attach_and_approve_proof(type)
    end

    def attach_and_approve_proof(type) # rubocop:disable Naming/PredicateMethod
      blob_or_file = params["#{type}_proof"].presence || params["#{type}_proof_signed_id"].presence

      result = ProofAttachmentService.attach_proof(
        application: @application,
        proof_type: type,
        blob_or_file: blob_or_file,
        status: :approved,
        admin: @admin,
        submission_method: :paper,
        metadata: {}
      )

      unless result[:success]
        add_error("Error processing #{type} proof: #{result[:error]&.message}")
        return false
      end

      @application.update!("#{type}_proof_status" => Application.public_send("#{type}_proof_statuses")['approved'])
      true
    end

    def process_reject_proof(type) # rubocop:disable Naming/PredicateMethod
      result = ProofAttachmentService.reject_proof_without_attachment(
        application: @application,
        proof_type: type,
        admin: @admin,
        reason: params["#{type}_proof_rejection_reason"],
        notes: params["#{type}_proof_rejection_notes"],
        submission_method: :paper,
        metadata: {}
      )

      unless result[:success]
        add_error("Error rejecting #{type} proof: #{result[:error]&.message}")
        return false
      end

      true
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

    def add_error(message) # rubocop:disable Naming/PredicateMethod
      @errors << message
      false
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n") if exception.backtrace
    end
  end
end
