# frozen_string_literal: true

module Applications
  class MedicalCertificationService < BaseService
    ACTION = 'MedicalProviderMailer#request_certification'
    STATE_FIELDS = %w[medical_certification_status medical_certification_requested_at medical_certification_request_count].freeze

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
      return failure('Medical provider email is required') if application.medical_provider_email.blank?

      decision, context = EmailDelivery.issuance(ACTION)
      return refusal(decision) if decision

      notification = nil
      application.with_lock do
        return failure('Auto-send is no longer applicable.') if automatic && !auto_requestable?

        previous = application.attributes.slice(*STATE_FIELDS)
        timestamp = Time.current
        Current.instance.set(skip_proof_validation: true) do
          application.update!(medical_certification_status: :requested, medical_certification_requested_at: timestamp,
                              medical_certification_request_count: application.medical_certification_request_count.to_i + 1)
        end
        application.reload
        notification = create_notification(previous)
        AuditEventService.log(action: 'medical_certification_requested', actor: actor, auditable: application,
                              metadata: { old_status: previous['medical_certification_status'], new_status: 'requested',
                                          change_type: 'medical_certification', notification_id: notification.id,
                                          submission_method: 'email', delivery_outcome: 'pending_enqueue' })
        context = context.merge('notification_id' => notification.id)
        ApplicationStatusChange.create!(application: application, user: actor,
                                        from_status: previous['medical_certification_status'], to_status: 'requested',
                                        change_type: 'medical_certification',
                                        metadata: { notification_id: notification.id, change_type: 'medical_certification' })
      end
      deferred = ActiveRecord::Base.current_transaction.open?
      job = EmailDelivery::Current.set(context: context, queued: true) do
        MedicalCertificationEmailJob.perform_later(application_id: application.id,
                                                   timestamp: application.medical_certification_requested_at.iso8601(6),
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

    # Only this owner's unchanged request can be compensated. A newer secure-link or DocuSeal
    # request wins, including another request within the same second.
    def self.restore_unsent_request(notification)
      state = notification.metadata&.dig('certification_request_state')
      return unless state && notification.notifiable.is_a?(Application)

      application = notification.notifiable
      application.with_lock do
        issued_at = Time.iso8601(state.fetch('issued_at'))
        next unless application.medical_certification_status_requested?
        next unless application.medical_certification_requested_at == issued_at
        next unless application.medical_certification_request_count == state['issued_count']
        next if application.document_signing_requested_at && application.document_signing_requested_at >= issued_at
        next if MedicalProviderSecureRequestForm.open_certification_upload_for_application(application_id: application.id)
                                                .exists?(created_at: issued_at..)

        Current.instance.set(skip_proof_validation: true) { application.update!(state.fetch('previous')) }
        ApplicationStatusChange.create!(application: application, user: notification.actor,
                                        from_status: 'requested', to_status: application.medical_certification_status,
                                        change_type: 'medical_certification',
                                        metadata: { change_type: 'medical_certification', reason: 'delivery_not_sent', notification_id: notification.id })
      end
    end

    private

    def auto_requestable?
      application.status_awaiting_dcf? && application.required_proofs_for_dcf_approved? && application.medical_certification_status_not_requested?
    end

    def refusal(decision)
      failure(decision.configuration_error? ? EmailDelivery::ConfigurationError::MESSAGE : I18n.t('outbound_delivery.delivery_suppressed'),
              { delivery_outcome: decision.outcome.to_sym, reason: decision.reason })
    end

    def create_notification(previous)
      resolver = Applications::SecureRequestRecipientResolver.new(application: application)
      recipient = resolver.known_recipients.find { |user| user.id == resolver.default_recipient_ids.first } || application.user
      NotificationService.create_and_deliver!(
        type: 'medical_certification_requested', recipient: recipient, actor: actor, notifiable: application,
        metadata: { request_count: application.medical_certification_request_count,
                    provider: application.medical_provider_name, provider_email: application.medical_provider_email,
                    certification_request_state: { previous: previous,
                                                   issued_at: application.medical_certification_requested_at.iso8601(6),
                                                   issued_count: application.medical_certification_request_count } },
        channel: :email, deliver: false
      ) || raise('Could not create certification tracking notification')
    end
  end
end
