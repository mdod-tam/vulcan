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
      with_issuance_errors(application) do
        return failure(message(:request_not_needed)) unless application.certification_requestable_via_secure_form?
        return failure(message(:provider_email_required)) if provider_email.blank?
        return failure(message(:unsupported_channel)) unless channel == :email

        if @deliver_email
          denial = authorize_delivery
          return denial if denial
        end

        delivery = nil

        ApplicationRecord.transaction do
          application.with_lock do
            delivery = create_request
            DisabilityCertificationService.new(application: application, actor: actor)
                                          .prepare_upload_request!(notification: Notification.find(delivery.notification_id))
          end
        end

        if @deliver_email
          result = deliver_requests([delivery])
          return result if result.failure?
        end

        success(message(:request_created), result_data(delivery.secure_request_form, delivery.raw_token))
      end
    rescue StandardError => e
      Rails.logger.warn("Certification upload request failed for application #{application.id}: #{e.class.name}")
      failure(message(:delivery_failed))
    end

    private

    # An application has one certifying provider, so a new request replaces every open one.
    def create_request
      issued = SecureFormReplacement.replace!(
        open: SecureRequestForm.open_certification_upload_for_application(application_id: application.id),
        actor: actor,
        attributes: request_form_attributes
      )
      request_form = issued.secure_request_form

      notification = create_tracking_notification(request_form) || raise('Could not create certification tracking notification')
      Delivery.new(secure_request_form: request_form, raw_token: issued.raw_token, context: @email_context, notification_id: notification.id)
    end

    def request_form_attributes
      {
        application: application,
        kind: :certification_upload,
        recipient_role: :provider,
        recipient_channel: :email,
        recipient_email: provider_email,
        recipient_name: provider_name
      }
    end

    def create_tracking_notification(request_form)
      NotificationService.create_and_deliver!(
        type: 'cert_upload_requested',
        recipient: tracking_notification_recipient,
        actor: actor,
        notifiable: application,
        metadata: {
          secure_request_form_id: request_form.id,
          application_id: application.id,
          request_batch_id: request_form.request_batch_id,
          provider_name: request_form.recipient_name,
          provider_email: request_form.recipient_email,
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
      rejection_delivery? ? 'CertifyingProfessionalMailer#certification_rejected' : 'CertifyingProfessionalMailer#request_certification'
    end

    def delivery_channel(_delivery) = :email

    def suppressed_delivery_data(deliveries)
      { secure_request_form: Array(deliveries).first&.secure_request_form }.compact
    end

    def delivery_failure_data(delivery_failures, deliveries)
      super.merge(suppressed_delivery_data(deliveries), delivery_failure: delivery_failures.first)
    end

    def delivery_failure_details(forms)
      request_form = forms.first
      { application_id: application.id, secure_request_form_id: request_form.id,
        request_batch_id: request_form.request_batch_id, recipient_ids: [],
        template_name: rejection_delivery? ? 'certifying_professional_certification_rejected' : 'certifying_professional_request_certification' }
    end

    def deliver_email(delivery)
      @email_context = delivery_context_for(delivery)
      deliver_request_email!(delivery.secure_request_form, delivery.raw_token)
    end

    def after_delivery_not_sent(delivery)
      DisabilityCertificationService.restore_unsent_request(Notification.find_by(id: delivery.notification_id))
    end

    def result_data(request_form, raw_token)
      {
        secure_request_form: request_form,
        secure_upload_url: secure_upload_url_for(raw_token)
      }
    end

    # Delivers to the provider email recorded on the request row.
    def deliver_request_email!(request_form, raw_token)
      secure_upload_url = secure_upload_url_for(raw_token)

      mail =
        if rejection_delivery?
          CertifyingProfessionalMailer.with(
            application: application,
            recipient_email: request_form.recipient_email,
            rejection_reason: rejection_reason_for_delivery,
            admin: actor,
            secure_upload_url: secure_upload_url
          ).certification_rejected
        else
          CertifyingProfessionalMailer.with(
            application: application,
            recipient_email: request_form.recipient_email,
            timestamp: Time.current.iso8601,
            secure_upload_url: secure_upload_url
          ).request_certification
        end
      EmailDelivery.deliver_now!(mail, context: @email_context)
    end

    def rejection_delivery?
      # The certification status selects the template. Secure certification
      # links serve only first requests and rejection follow-ups.
      application.disability_certification_status_rejected?
    end

    def rejection_reason_for_delivery
      latest_review = application.latest_disability_certification_rejection_review
      latest_review&.rejection_reason.presence ||
        application.disability_certification_rejection_reason.presence ||
        I18n.t('secure_certification_form_resends.create.default_rejection_reason')
    end

    def secure_upload_url_for(raw_token)
      SecureFormPolicy.public_url(:secure_certification_form_url, raw_token)
    end

    # A resend uses the provider on file now, not the one on the expired link.
    def provider_email
      application.certifying_professional_email
    end

    def provider_name
      application.certifying_professional_name
    end
  end
end
