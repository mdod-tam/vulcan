# frozen_string_literal: true

module Applications
  # Runs the independent follow-up steps after a confirmed paper application commit.
  class PaperCreationFollowUp
    class StepFailure < StandardError; end

    attr_reader :reconciliation_note

    # rubocop:disable-next Metrics/ParameterLists -- preserve the intake's explicit participants and account handoffs
    def initialize(application:, admin:, params:, constituent:, guardian_user_for_app:,
                   created_portal_user_ids:, quick_created_portal_user_ids:, warnings:)
      @application = application
      @admin = admin
      @params = params
      @constituent = constituent
      @guardian_user_for_app = guardian_user_for_app
      @created_portal_user_ids = created_portal_user_ids
      @quick_created_portal_user_ids = quick_created_portal_user_ids
      @warnings = warnings
    end

    # Attempt each step independently; the application is already durable.
    def call
      run_post_creation_step('the creation audit event') { log_application_creation }
      run_post_creation_step('notifications') { send_notifications }
      run_post_creation_step('proof delivery checks') { append_proof_resubmission_delivery_warnings }
      run_post_creation_step('the certifying provider request') { request_provider_info_if_missing }
    end

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

    private

    attr_reader :params

    def run_post_creation_step(description)
      yield
    rescue StandardError => e
      # The wrapper carries staff guidance. Its cause supplies the diagnostic error class.
      diagnostic = e.cause || e
      log_error(diagnostic, "Paper application post-creation step failed: #{description}")
      detail = e.is_a?(StepFailure) ? "#{e.message} " : ''
      add_warning("The application was created, but #{description} did not finish. #{detail}" \
                  'Review this application before treating it as complete.')
      record_incomplete_follow_up(description, diagnostic)
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

    def send_notifications
      send_disability_certification_not_provided_notice
      send_account_creation_notifications
    end

    def request_provider_info_if_missing
      return unless params[:no_certifying_professional_information]
      return if @application.disability_certification_status_approved?

      result = Applications::RequestProviderInfo.new(
        application: @application,
        actor: @admin
      ).call

      return if result.success?

      raise StepFailure,
            "It could not be sent automatically: #{result.message} You can send it from the application page."
    rescue StepFailure
      raise
    rescue StandardError
      # Wrap the exception to preserve manual-send guidance. The wrapper logs and audits the original cause.
      raise StepFailure,
            'It could not be sent automatically. You can send it from the application page.'
    end

    def send_disability_certification_not_provided_notice
      not_provided = @application.proof_reviews.reload.rejections.find_by(
        proof_type: :disability_certification,
        rejection_reason_code: 'none_provided'
      )
      return unless not_provided

      NotificationService.create_and_deliver!(
        type: 'disability_certification_not_provided',
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
        support_email: ProgramContact.support_email,
        program_website_url: ProgramContact.website_url
      }
    end

    def add_warning(message)
      @warnings << message unless @warnings.include?(message)
    end

    def log_error(exception, message)
      Rails.logger.error "#{message}: #{exception.class.name}"
    end
  end
end
