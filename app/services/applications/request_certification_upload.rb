# frozen_string_literal: true

module Applications
  class RequestCertificationUpload < BaseService
    include SecureFormLocaleResolver
    include Applications::SecureRequestDeliveryPolicy

    MESSAGE_SCOPE = 'applications.certification_upload.messages'

    attr_reader :application, :actor, :channel, :resend_of, :public_recovery

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

      if @deliver_email
        denial = authorize_delivery
        return denial if denial
      end

      delivery = nil

      ApplicationRecord.transaction do
        application.with_lock do
          ensure_cooldown_allows!
          revoke_open_requests
          delivery = create_request
          transition_initial_status_if_needed(delivery)
        end
      end

      if @deliver_email
        result = deliver_requests([delivery])
        return result if result.failure?
      end

      success(message(:request_created), result_data(delivery.secure_request_form, delivery.raw_token))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Certification upload request failed for application #{application.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent)) if public_recovery

      failure(e.message)
    rescue StandardError => e
      Rails.logger.warn("Certification upload request failed for application #{application.id}: #{sanitize_secure_error_message(e.message)}")
      failure(message(:delivery_failed))
    end

    private

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

      notification = create_tracking_notification(request_form) || raise('Could not create certification tracking notification')
      Delivery.new(secure_request_form: request_form, raw_token: raw_token, context: @email_context, notification_id: notification.id)
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

    def delivery_mail_action
      rejection_delivery? ? 'MedicalProviderMailer#certification_rejected' : 'MedicalProviderMailer#request_certification'
    end

    def delivery_channel(_delivery) = :email

    def suppressed_delivery_data(deliveries)
      { medical_provider_secure_request_form: Array(deliveries).first&.secure_request_form }.compact
    end

    def delivery_failure_data(delivery_failures, deliveries)
      super.merge(suppressed_delivery_data(deliveries), delivery_failure: delivery_failures.first)
    end

    def delivery_failure_details(forms)
      request_form = forms.first
      { application_id: application.id, medical_provider_secure_request_form_id: request_form.id,
        request_batch_id: request_form.request_batch_id, recipient_ids: [],
        template_name: rejection_delivery? ? 'medical_provider_certification_rejected' : 'medical_provider_request_certification' }
    end

    def deliver_email(delivery)
      @email_context = delivery_context_for(delivery)
      deliver_request_email!(delivery.secure_request_form, delivery.raw_token)
    end

    def after_delivery_not_sent(delivery)
      MedicalCertificationService.restore_unsent_request(Notification.find_by(id: delivery.notification_id))
    end

    def transition_initial_status_if_needed(delivery)
      return unless application.medical_certification_status_not_requested?

      previous = application.attributes.slice(*MedicalCertificationService::STATE_FIELDS)
      with_proof_validation_skipped do
        application.update!(
          medical_certification_status: :requested,
          medical_certification_requested_at: Time.current
        )
      end
      application.reload
      Notification.find(delivery.notification_id).update_metadata!(
        'certification_request_state',
        MedicalCertificationService.request_state(application, previous: previous)
      )
      record_status_transition(previous['medical_certification_status'])
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
