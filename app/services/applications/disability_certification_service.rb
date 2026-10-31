# frozen_string_literal: true

module Applications
  class DisabilityCertificationService < BaseService
    ACTION = 'CertifyingProfessionalMailer#request_certification'
    STATE_FIELDS = %w[disability_certification_status disability_certification_requested_at disability_certification_request_count].freeze

    attr_reader :application, :actor

    def initialize(application:, actor:)
      super()
      @application = application
      @actor = actor
    end

    def auto_request_certification
      application.reload
      result = request_certification(automatic: true)
      unless result.success?
        AuditEventService.log(action: 'dcf_auto_request_not_sent', actor: actor, auditable: application,
                              metadata: { reason: result.message, delivery_outcome: result.data&.dig(:delivery_outcome) })
      end
      result
    rescue StandardError => e
      Rails.logger.error("DCF auto-request failed for application #{application.id}: #{e.class.name}")
      failure('Auto-send not sent — request manually.')
    end

    def request_certification(automatic: false)
      return failure('Certifying professional email is required') if application.certifying_professional_email.blank?

      decision, context = EmailDelivery.issuance(ACTION)
      return refusal(decision) if decision

      notification = nil
      application.with_lock do
        return failure('Auto-send is no longer applicable.') if automatic && !auto_requestable?

        notification = create_notification
        record_request!(notification: notification, submission_method: 'email',
                        request_count: application.disability_certification_request_count.to_i + 1,
                        delivery_outcome: 'pending_enqueue')
        context = context.merge('notification_id' => notification.id)
      end
      deferred = ActiveRecord::Base.current_transaction.open?
      job = EmailDelivery::Current.set(context: context, queued: true) do
        DisabilityCertificationEmailJob.perform_later(application_id: application.id,
                                                      timestamp: application.disability_certification_requested_at.iso8601(6),
                                                      notification_id: notification.id)
      end
      if job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued?
        return success(deferred ? 'Certification email scheduled after commit.' : 'Certification email queued.',
                       { delivery_outcome: deferred ? :deferred : :queued })
      end

      decision = EmailDelivery::Policy.verify(context)
      return refusal(decision) unless decision.allowed?

      self.class.restore_unsent_request(notification)
      failure('Certification email could not be queued.', { delivery_outcome: :enqueue_failed })
    rescue StandardError => e
      self.class.restore_unsent_request(notification) if notification
      log_error(e, "Application ID: #{application.id}")
      failure('Certification email could not be queued.', { delivery_outcome: :enqueue_failed })
    end

    # Preparing an upload link is not a counted provider request. Replacements and
    # rejection follow-ups retain the existing certification state and request count.
    def prepare_upload_request!(notification:)
      application.with_lock do
        if application.disability_certification_status_not_requested?
          record_request!(notification: notification, submission_method: 'secure_form',
                          request_count: application.disability_certification_request_count)
        end
      end
    end

    # JSON's default timestamp format drops microseconds needed for exact restoration.
    def self.request_state(application, previous:)
      {
        'previous' => previous.merge('disability_certification_requested_at' => previous['disability_certification_requested_at']&.iso8601(6)),
        'issued_at' => application.disability_certification_requested_at.iso8601(6),
        'issued_count' => application.disability_certification_request_count
      }
    end

    # Restore only this notification's unchanged request after its email was not sent.
    # An open secure request or a newer DocuSeal request still owns the requested state.
    def self.restore_unsent_request(notification)
      state = notification&.metadata&.dig('certification_request_state')
      return unless state && notification.notifiable.is_a?(Application)

      application = notification.notifiable
      application.with_lock(requires_new: true) do
        issued_at = Time.iso8601(state.fetch('issued_at'))
        next unless application.disability_certification_status_requested?
        next unless application.disability_certification_requested_at == issued_at
        next unless application.disability_certification_request_count == state['issued_count']
        next if application.document_signing_requested_at && application.document_signing_requested_at >= issued_at
        next if SecureRequestForm.open_certification_upload_for_application(application_id: application.id).exists?

        previous = state.fetch('previous')
        metadata = { reason: 'delivery_not_sent', notification_id: notification.id }
        request_form_id = notification.metadata['secure_request_form_id']
        metadata[:secure_request_form_id] = request_form_id if request_form_id
        application.transition_disability_certification_status!(
          previous.fetch('disability_certification_status'),
          actor: notification.actor,
          action: 'disability_certification_request_not_sent',
          attributes: previous.except('disability_certification_status'),
          metadata: metadata
        )
      end
    end

    private

    def auto_requestable?
      application.status_awaiting_dcf? && application.required_proofs_for_dcf_approved? && application.disability_certification_status_not_requested?
    end

    def refusal(decision)
      failure(decision.configuration_error? ? EmailDelivery::ConfigurationError::MESSAGE : I18n.t('outbound_delivery.delivery_suppressed'),
              { delivery_outcome: decision.outcome.to_sym, reason: decision.reason })
    end

    # Caller holds the application lock; state, tracking, history and audit commit together.
    def record_request!(notification:, submission_method:, request_count:, delivery_outcome: nil)
      previous = application.attributes.slice(*STATE_FIELDS)
      application.transition_disability_certification_status!(
        :requested,
        actor: actor,
        action: 'disability_certification_requested',
        attributes: { disability_certification_requested_at: Time.current, disability_certification_request_count: request_count },
        metadata: { notification_id: notification.id, requested_by_id: actor&.id, submission_method: submission_method,
                    delivery_outcome: delivery_outcome }.compact
      )
      application.reload
      notification.update_metadata!('certification_request_state', self.class.request_state(application, previous: previous))
      notification.update_metadata!('request_count', request_count)
    end

    def create_notification
      resolver = Applications::SecureRequestRecipientResolver.new(application: application)
      recipient = resolver.known_recipients.find { |user| user.id == resolver.default_recipient_ids.first } || application.user
      NotificationService.create_and_deliver!(
        type: 'disability_certification_requested', recipient: recipient, actor: actor, notifiable: application,
        metadata: { provider: application.certifying_professional_name, provider_email: application.certifying_professional_email },
        channel: :email, deliver: false
      )
    end
  end
end
