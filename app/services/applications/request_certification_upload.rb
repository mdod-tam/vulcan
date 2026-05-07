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

      deliver_request_email!(raw_token) if deliver_email

      success(message(:request_created), result_data(request_form, raw_token))
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("Certification upload request failed for application #{application.id}: #{e.message}")
      failure(message(:request_conflict))
    rescue CooldownActive => e
      return success(message(:resent)) if public_recovery

      failure(e.message)
    rescue StandardError => e
      Rails.logger.warn("Certification upload delivery failed for application #{application.id}: #{sanitize_secure_error_message(e.message)}")
      request_form&.persisted? ? delivery_failure(request_form, e) : failure(message(:delivery_failed))
    end

    private

    def ensure_cooldown_allows!
      latest_request = MedicalProviderSecureRequestForm
                       .certification_upload
                       .where(application: application, provider_email: provider_email)
                       .order(sent_at: :desc)
                       .first
      return if latest_request.blank?

      cooldown_until = latest_request.sent_at + resend_cooldown_hours.hours
      return if cooldown_until <= Time.current

      minutes = ((cooldown_until - Time.current) / 60.0).ceil
      raise CooldownActive, message(:cooldown_active, minutes: minutes)
    end

    def revoke_open_requests
      MedicalProviderSecureRequestForm
        .open_certification_upload_for_provider(
          application_id: application.id,
          provider_email: provider_email
        )
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
        expires_at: link_expiration_hours.hours.from_now,
        sent_at: Time.current,
        request_batch_id: SecureRandom.uuid,
        requested_by: actor
      }
    end

    def create_tracking_notification(request_form)
      NotificationService.create_and_deliver!(
        type: 'cert_upload_requested',
        recipient: application.user,
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

    def delivery_failure(request_form, error)
      persist_delivery_failure(request_form, error)
      failure(message(:delivery_failed), delivery_failure_data(request_form, error))
    end

    def persist_delivery_failure(request_form, error)
      notification = tracking_notification_for(request_form)
      return if notification.blank?

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
      record_status_transition(previous_status)
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

    def deliver_request_email!(raw_token)
      secure_upload_url = secure_upload_url_for(raw_token)

      if rejection_delivery?
        MedicalProviderMailer.with(
          application: application,
          rejection_reason: rejection_reason_for_delivery,
          admin: actor,
          secure_upload_url: secure_upload_url
        ).certification_rejected.deliver_now
      else
        MedicalProviderMailer.with(
          application: application,
          timestamp: Time.current.iso8601,
          secure_upload_url: secure_upload_url
        ).request_certification.deliver_now
      end
    end

    def rejection_delivery?
      # We intentionally infer the delivery template from the application's
      # current certification state rather than storing a second context column
      # on the request row. In the current codebase, secure cert links are only
      # used for initial requests and rejection follow-ups.
      application.medical_certification_status_rejected?
    end

    def rejection_reason_for_delivery
      latest_review = application.latest_medical_rejection_review
      latest_review&.rejection_reason.presence ||
        application.medical_certification_rejection_reason.presence ||
        I18n.t('secure_certification_form_resends.create.default_rejection_reason')
    end

    def secure_upload_url_for(raw_token)
      options = Rails.application.config.action_mailer.default_url_options || {}
      host = options[:host]
      protocol = options[:protocol] || (Rails.env.production? ? 'https' : 'http')

      if Rails.env.production?
        raise ArgumentError, 'Secure certification form host is not configured' if host.blank? || host == 'example.com'
        raise ArgumentError, 'Secure certification form URLs must use HTTPS in production' unless protocol == 'https'
      end

      Rails.application.routes.url_helpers.secure_certification_form_url(
        token: raw_token,
        host: host,
        port: options[:port],
        protocol: protocol
      )
    end

    def link_expiration_hours
      Policy.get('secure_form_link_expiration_hours') || 48
    end

    def resend_cooldown_hours
      Policy.get('secure_form_resend_cooldown_hours') || 1
    end

    def provider_email
      resend_of&.provider_email.presence || application.medical_provider_email
    end

    def provider_name
      resend_of&.provider_name.presence || application.medical_provider_name
    end

    def message(key, **)
      I18n.t("#{MESSAGE_SCOPE}.#{key}", **, locale: secure_form_locale_for(actor))
    end

    class CooldownActive < StandardError; end
  end
end
