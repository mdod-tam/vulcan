# frozen_string_literal: true

module DocumentSigning
  # Asks the certifying provider to sign the disability certification form through DocuSeal and records the request.
  class SubmissionService < BaseService
    EMAIL_ACTION = 'DocuSeal#signing_request'

    attr_reader :service_type

    def initialize(application:, actor:, service: 'docuseal')
      super()
      @application = application
      @actor = actor
      @service_type = service
    end

    def call
      @submission = nil
      @handoff_started = false
      return failure('Actor is required') if @actor.blank?

      with_submission_lock do |connection|
        @application.reload
        refusal = request_refusal
        next refusal if refusal
        next failure('Signing requests must be sent outside a database transaction.') if connection.transaction_open?

        @operation_id = SecureRandom.uuid
        @submission = create_submission!
        record_submission!
        success('Document signing request created', @submission)
      end
    rescue EmailDelivery::ConfigurationError => e
      failure(I18n.t('email_delivery.configuration_error', locale: :en),
              { delivery_error: true, configuration_error: true, reason: e.reason })
    rescue StandardError => e
      log_error(e, application_id: @application.id)
      return handoff_failure(e) if @handoff_started || @submission

      failure('Failed to create document signing request.')
    end

    private

    # A session lock spans the provider call without holding a database transaction open.
    def with_submission_lock
      Application.connection_pool.with_connection do |connection|
        key = Digest::SHA256.digest("document-signing-submission:#{@application.id}").unpack1('q>')
        bind = ActiveRecord::Relation::QueryAttribute.new('lock_key', key, ActiveRecord::Type::Integer.new(limit: 8))
        locked = connection.select_value('SELECT pg_try_advisory_lock($1)', 'Signing request lock', [bind])
        next failure('A signing request is already running for this application. Please wait.', { already_running: true }) unless locked

        begin
          yield connection
        ensure
          unlock_submission(connection, bind)
        end
      end
    end

    def unlock_submission(connection, bind)
      connection.select_value('SELECT pg_advisory_unlock($1)', 'Signing request unlock', [bind])
    rescue StandardError
      # Do not return a session that may still own this lock to the pool.
      connection.disconnect!
      raise
    end

    def request_refusal
      return failure('Certifying professional email is required') if @application.certifying_professional_email.blank?
      return failure('Certifying professional name is required') if @application.certifying_professional_name.blank?

      if @application.document_signing_requested_at.present? &&
         @application.document_signing_requested_at > 30.seconds.ago
        return failure('Request sent too recently. Please wait before sending another.')
      end

      # DocuSeal emails the provider itself, so the email controls are checked here, next to the call.
      # A denied request makes no submission and changes no status, timestamp, or counter.
      denial = EmailDelivery.issuance_denial(EMAIL_ACTION)
      return unless denial

      failure('Signing request not sent: DocuSeal emails the provider, and that email is turned off ' \
              'in the communication settings. Blank forms remain available; outgoing letters follow their own controls.',
              { delivery_suppressed: true, suppression_reason: denial.reason })
    end

    def record_submission!
      raise ArgumentError, 'DocuSeal returned no submission identity' if submission_id.blank?

      submitter = @submission['submitters']&.first

      @application.with_lock do
        requested_at = Time.current
        @application.transition_disability_certification_status!(
          :requested,
          actor: @actor,
          action: 'disability_certification_requested',
          attributes: {
            document_signing_service: @service_type,
            document_signing_submission_id: submission_id,
            document_signing_submitter_id: submitter&.dig('id').to_s,
            document_signing_status: :sent,
            document_signing_requested_at: requested_at,
            disability_certification_requested_at: requested_at,
            document_signing_request_count: @application.document_signing_request_count.to_i + 1,
            disability_certification_request_count: @application.disability_certification_request_count.to_i + 1
          },
          metadata: { submission_method: 'document_signing', provider_name: @application.certifying_professional_name,
                      requested_by_id: @actor.id }
        )

        AuditEventService.log(
          action: 'document_signing_request_sent',
          actor: @actor,
          auditable: @application,
          metadata: {
            operation_id: "document-signing-#{@service_type}-#{submission_id}",
            document_signing_service: @service_type,
            document_signing_submission_id: submission_id,
            provider_name: @application.certifying_professional_name,
            provider_email: @application.certifying_professional_email,
            submission_method: 'document_signing'
          }
        )
      end
    end

    def handoff_failure(error)
      state = submission_commit_state
      data = { recovery_required: true, commit_state: state, retryable: false,
               document_signing_submission_id: submission_id, provider_acceptance: submission_id ? :accepted : :unknown }
      data[:tracking_failed] = true unless record_handoff_failure(error, data)

      message = if state == :committed
                  'DocuSeal accepted the signing request and it was saved, but follow-up work failed. Check the request before sending another.'
                elsif submission_id
                  'DocuSeal accepted the signing request, but its local record could not be confirmed. Check DocuSeal and this application before sending another.'
                else
                  'DocuSeal may have accepted the signing request. Check DocuSeal and this application before sending another.'
                end
      message += ' The recovery audit could not be recorded.' if data[:tracking_failed]
      state == :committed ? success(message, data.merge(warning: true)) : failure(message, data)
    end

    def submission_commit_state
      return :rolled_back unless submission_id

      Application.find(@application.id).document_signing_submission_id == submission_id ? :committed : :rolled_back
    rescue StandardError
      :unknown
    end

    def record_handoff_failure(error, data)
      # A rolled-back instance can retain dirty attributes; never audit that instance.
      application = Application.find(@application.id)
      AuditEventService.log(
        action: data[:commit_state] == :committed ? 'document_signing_follow_up_failed' : 'document_signing_request_unconfirmed',
        actor: @actor,
        auditable: application,
        metadata: data.except(:recovery_required, :retryable).merge(
          application_id: application.id, operation_id: @operation_id, error_class: error.class.name
        ).compact
      )
      true
    rescue StandardError => e
      Rails.logger.error "Could not record signing request recovery for Application #{@application.id}: #{e.class.name}"
      false
    end

    def submission_id
      @submission['id'].presence&.to_s if @submission.is_a?(Hash)
    end

    def create_submission!
      data = {
        name: submission_name,
        submitters: [{
          role: 'Certifying Professional',
          email: @application.certifying_professional_email,
          name: @application.certifying_professional_name
        }],
        send_email: true,
        message: {
          subject: request_message_subject,
          body: request_message_body
        },
        completed_redirect_url: Rails.application.routes.url_helpers.admin_application_url(
          @application,
          host: Rails.application.config.action_mailer.default_url_options[:host]
        )
      }

      # Creates the submission from a DocuSeal template.
      @handoff_started = true
      ::Docuseal.create_submission(data)
    end

    def request_message_subject
      I18n.t(
        'document_signing.disability_certification_request.subject',
        locale: request_locale,
        constituent_full_name: constituent.full_name
      )
    end

    def request_message_body
      I18n.t(
        'document_signing.disability_certification_request.body',
        locale: request_locale,
        constituent_full_name: constituent.full_name,
        constituent_dob_formatted: constituent.date_of_birth&.strftime('%m/%d/%Y') || localized_not_provided,
        constituent_phone_formatted: constituent.phone.presence || localized_not_provided,
        constituent_email: constituent.email.presence || localized_not_provided,
        constituent_address_formatted: constituent_address_formatted,
        application_id: @application.id,
        support_email: ProgramContact.support_email
      )
    end

    def submission_name
      I18n.t(
        'document_signing.disability_certification_request.submission_name',
        locale: request_locale,
        constituent_full_name: constituent.full_name,
        application_id: @application.id
      )
    end

    def request_locale
      constituent.locale.presence || I18n.default_locale.to_s
    end

    def constituent
      @application.user
    end

    def constituent_address_formatted
      [
        constituent.physical_address_1,
        constituent.physical_address_2,
        "#{constituent.city}, #{constituent.state} #{constituent.zip_code}"
      ].compact_blank.join("\n").presence || localized_not_provided
    end

    def localized_not_provided
      request_locale.to_s == 'es' ? 'No proporcionado' : 'Not Provided'
    end
  end
end
