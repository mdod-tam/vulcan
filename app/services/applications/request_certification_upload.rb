# frozen_string_literal: true

module Applications
  class RequestCertificationUpload < BaseService
    include SecureFormLocaleResolver

    MESSAGE_SCOPE = 'applications.certification_upload.messages'

    attr_reader :application, :actor, :channel, :resend_of, :public_recovery, :deliver_email

    def initialize(application:, actor:, channel: :email, resend_of: nil, public_recovery: false, deliver_email: false)
      super()
      @application = application
      @actor = actor
      @channel = channel&.to_sym
      @resend_of = resend_of
      @public_recovery = public_recovery
      @deliver_email = deliver_email
    end

    def call
      return failure(message(:provider_email_required)) if provider_email.blank?
      return failure(message(:unsupported_channel)) unless channel == :email

      # An email-issuing request is checked before any request, token, revocation, or status change.
      if deliver_email
        denial, @email_context = EmailDelivery.issuance(delivery_mail_action)
        denial&.raise_if_configuration_error!
        return suppressed(denial.reason) if denial
      end

      request_form = nil
      raw_token = nil

      ApplicationRecord.transaction do
        application.with_lock do
          ensure_cooldown_allows!
          revoke_open_requests
          request_form, raw_token = create_request
          transition_initial_status_if_needed
        end
      end

      deliver_request_email!(request_form, raw_token) if deliver_email

      success(message(:request_created), result_data(request_form, raw_token))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Certification upload request failed for application #{application.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent)) if public_recovery

      failure(e.message)
    rescue EmailDelivery::ConfigurationError => e
      configuration_failure(request_form, e)
    rescue ApplicationMailer::DeliverySkipped => e
      request_form&.persisted? ? delivery_suppressed(request_form, e.reason) : suppressed(e.reason)
    rescue StandardError => e
      Rails.logger.warn("Certification upload delivery failed for application #{application.id}: #{sanitize_secure_error_message(e.message)}")
      request_form&.persisted? ? delivery_failure(request_form, e) : failure(message(:delivery_failed))
    end

    private

    def configuration_failure(request_form, error)
      data = request_form&.persisted? ? delivery_failure(request_form, error).data : {}
      failure(I18n.t('email_delivery.configuration_error', locale: secure_form_locale_for(actor)),
              data.merge(delivery_error: true, configuration_error: true, reason: error.reason))
    end

    def ensure_cooldown_allows!
      latest_request = MedicalProviderSecureRequestForm
                       .open_certification_upload_for_application(application_id: application.id)
                       .order(sent_at: :desc)
                       .first
      return if latest_request.blank?

      cooldown_until = latest_request.sent_at + SecureFormPolicy.resend_cooldown_hours.hours
      return if cooldown_until <= Time.current

      minutes = ((cooldown_until - Time.current) / 60.0).ceil
      raise CooldownActive, message(:cooldown_active, minutes: minutes)
    end

    def revoke_open_requests
      MedicalProviderSecureRequestForm
        .open_certification_upload_for_application(application_id: application.id)
        .find_each { |request_form| request_form.revoke!(actor: actor, reason: :replacement_request) }
    end

    def create_request
      request_form = nil
      raw_token = nil
      attempts = 0

      begin
        attempts += 1
        raw_token = MedicalProviderSecureRequestForm.generate_public_token
        request_form = MedicalProviderSecureRequestForm.create!(request_form_attributes(raw_token))
      rescue ActiveRecord::RecordNotUnique
        retry if attempts < 2

        raise
      end

      create_tracking_notification(request_form)
      [request_form, raw_token]
    end

    def request_form_attributes(raw_token)
      {
        application: application,
        kind: :certification_upload,
        status: :sent,
        provider_email: provider_email,
        provider_name: provider_name,
        public_token_digest: MedicalProviderSecureRequestForm.digest_public_token(raw_token),
        expires_at: SecureFormPolicy.expires_at,
        sent_at: Time.current,
        request_batch_id: SecureRandom.uuid,
        requested_by: actor
      }
    end

    def create_tracking_notification(request_form)
      NotificationService.create_and_deliver!(
        type: 'cert_upload_requested',
        recipient: tracking_notification_recipient,
        actor: actor,
        notifiable: application,
        metadata: {
          medical_provider_secure_request_form_id: request_form.id,
          application_id: application.id,
          request_batch_id: request_form.request_batch_id,
          provider_name: request_form.provider_name,
          provider_email: request_form.provider_email,
          requested_channel: channel.to_s,
          expires_at: request_form.expires_at.iso8601
        },
        channel: :email,
        audit: true,
        deliver: false
      )
    end

    def tracking_notification_recipient
      resolver = Applications::SecureRequestRecipientResolver.new(application: application)
      default_recipient_id = resolver.default_recipient_ids.first

      resolver.known_recipients.find { |recipient| recipient.id == default_recipient_id } || application.user
    end

    # The email was stopped on purpose: revoke the unsent link, keep no cooldown, and say why.
    def delivery_suppressed(request_form, reason)
      tracking_notification_for(request_form)&.mark_delivery_suppressed!(reason)
      request_form.revoke!(actor: actor, reason: :delivery_suppressed, metadata: { suppression_reason: reason })
      revert_initial_status_after_suppression(request_form)
      suppressed(reason, request_form)
    end

    def suppressed(reason, request_form = nil)
      failure(message(:delivery_suppressed),
              { medical_provider_secure_request_form: request_form, delivery_suppressed: true,
                suppression_reason: reason }.compact)
    end

    def delivery_mail_action
      rejection_delivery? ? 'MedicalProviderMailer#certification_rejected' : 'MedicalProviderMailer#request_certification'
    end

    def delivery_failure(request_form, error)
      persist_delivery_failure(request_form, error)
      revoke_failed_request(request_form, error)
      failure(message(:delivery_failed), delivery_failure_data(request_form, error))
    end

    def revoke_failed_request(request_form, error)
      return unless request_form&.active?

      request_form.revoke!(
        actor: actor,
        reason: :delivery_failure,
        metadata: { delivery_failure: delivery_failure_context(request_form, error) }
      )
    rescue StandardError => e
      Rails.logger.error(
        "Certification upload delivery failure revocation failed: #{sanitize_secure_error_message(e.message)}"
      )
    end

    def persist_delivery_failure(request_form, error)
      notification = tracking_notification_for(request_form)
      return if notification.blank?

      if error.is_a?(EmailDelivery::ConfigurationError)
        notification.mark_delivery_not_sent!(EmailDelivery::Decision.configuration_error(error.reason))
        return
      end

      notification.update!(
        delivery_status: :error,
        metadata: (notification.metadata || {}).merge(
          delivery_error: delivery_failure_context(request_form, error)
        )
      )
    end

    def tracking_notification_for(request_form)
      Notification
        .where(notifiable: application, action: 'cert_upload_requested')
        .where("metadata->>'medical_provider_secure_request_form_id' = ?", request_form.id.to_s)
        .order(created_at: :desc)
        .first
    end

    def delivery_failure_data(request_form, error)
      {
        medical_provider_secure_request_form: request_form,
        delivery_error: true,
        delivery_failure: delivery_failure_context(request_form, error)
      }
    end

    def delivery_failure_context(request_form, error)
      {
        error_class: error.class.name,
        error_message: sanitize_secure_error_message(error.message),
        application_id: application.id,
        medical_provider_secure_request_form_id: request_form.id,
        request_batch_id: request_form.request_batch_id,
        provider_email: request_form.provider_email,
        template_name: rejection_delivery? ? 'medical_provider_certification_rejected' : 'medical_provider_request_certification'
      }
    end

    def transition_initial_status_if_needed
      return unless application.medical_certification_status_not_requested?

      previous_status = application.medical_certification_status
      with_proof_validation_skipped do
        application.update!(
          medical_certification_status: :requested,
          medical_certification_requested_at: Time.current
        )
      end
      # The stored value, at database precision, identifies this transition later.
      @requested_at_set = application.reload.medical_certification_requested_at
      record_status_transition(previous_status)
    end

    # When this call moved certification to requested and its email was then stopped, undo only that
    # move: the state must still be exactly the one this call set, with no other open request and no
    # DocuSeal request made since.
    def revert_initial_status_after_suppression(request_form)
      return if @requested_at_set.blank?

      application.with_lock do
        application.reload
        next unless application.medical_certification_status_requested?
        next unless application.medical_certification_requested_at == @requested_at_set
        next if application.document_signing_requested_at.present? && application.document_signing_requested_at >= @requested_at_set
        next if MedicalProviderSecureRequestForm.open_certification_upload_for_application(application_id: application.id)
                                                .where.not(id: request_form.id).exists?

        with_proof_validation_skipped do
          application.update!(medical_certification_status: :not_requested, medical_certification_requested_at: nil)
        end
        record_suppressed_request_reversal(request_form)
      end
    end

    def record_suppressed_request_reversal(request_form)
      ApplicationStatusChange.create!(
        application: application, user: actor, from_status: 'requested', to_status: 'not_requested',
        change_type: 'medical_certification',
        metadata: { change_type: 'medical_certification', reason: 'delivery_suppressed',
                    medical_provider_secure_request_form_id: request_form.id }
      )
      AuditEventService.log(
        action: 'medical_certification_request_suppressed',
        actor: actor,
        auditable: application,
        metadata: { old_status: 'requested', new_status: 'not_requested',
                    medical_provider_secure_request_form_id: request_form.id }
      )
    end

    def with_proof_validation_skipped
      # This status-only cert transition preserves Application update! callbacks
      # but must not require unrelated income/residency attachments.
      previous_value = Current.skip_proof_validation
      Current.skip_proof_validation = true
      yield
    ensure
      Current.skip_proof_validation = previous_value
    end

    def record_status_transition(previous_status)
      ApplicationStatusChange.create!(
        application: application,
        user: actor,
        from_status: previous_status || 'not_requested',
        to_status: 'requested',
        change_type: 'medical_certification',
        metadata: {
          change_type: 'medical_certification',
          requested_by_id: actor&.id,
          submission_method: 'secure_form'
        }
      )

      AuditEventService.log(
        action: 'medical_certification_requested',
        actor: actor,
        auditable: application,
        metadata: {
          old_status: previous_status || 'not_requested',
          new_status: 'requested',
          change_type: 'medical_certification',
          submission_method: 'secure_form'
        }
      )
    end

    def result_data(request_form, raw_token)
      {
        medical_provider_secure_request_form: request_form,
        secure_upload_url: secure_upload_url_for(raw_token)
      }
    end

    # Delivers to the provider email recorded on the request row.
    def deliver_request_email!(request_form, raw_token)
      secure_upload_url = secure_upload_url_for(raw_token)

      mail =
        if rejection_delivery?
          MedicalProviderMailer.with(
            application: application,
            recipient_email: request_form.provider_email,
            rejection_reason: rejection_reason_for_delivery,
            admin: actor,
            secure_upload_url: secure_upload_url
          ).certification_rejected
        else
          MedicalProviderMailer.with(
            application: application,
            recipient_email: request_form.provider_email,
            timestamp: Time.current.iso8601,
            secure_upload_url: secure_upload_url
          ).request_certification
        end
      EmailDelivery.deliver_now!(mail, context: @email_context)
    end

    def rejection_delivery?
      # The certification status selects the template. Secure certification
      # links serve only first requests and rejection follow-ups.
      application.medical_certification_status_rejected?
    end

    def rejection_reason_for_delivery
      latest_review = application.latest_medical_rejection_review
      latest_review&.rejection_reason.presence ||
        application.medical_certification_rejection_reason.presence ||
        I18n.t('secure_certification_form_resends.create.default_rejection_reason')
    end

    def secure_upload_url_for(raw_token)
      SecureFormPolicy.public_url(:secure_certification_form_url, raw_token)
    end

    # A resend uses the provider on file now, not the one on the expired link.
    def provider_email
      application.medical_provider_email
    end

    def provider_name
      application.medical_provider_name
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(actor))
    end

    class CooldownActive < StandardError; end
  end
end
