# frozen_string_literal: true

module EmailDelivery
  # The application's mail delivery job. It captures the delivery context when the email is
  # queued and carries it through retries, so a worker checks the controls as they stood when
  # the email was requested rather than granting fresh authorization.
  class MailDeliveryJob < ActionMailer::MailDeliveryJob
    include EmailDeliveryContextJob

    # Queue only after the caller's transaction commits.
    self.enqueue_after_transaction_commit = true

    # A mailer param deleted after queueing (a removed user, or one whose role changed) cannot be loaded.
    # The notice is for someone or something that no longer exists, so record it as not sent.
    discard_on ActiveJob::DeserializationError do |job, _error|
      EmailDelivery::Outcome.record_not_sent(EmailDelivery::Decision.suppressed(:assignment_superseded),
                                             context: job.email_delivery_context, mail_action: job.email_delivery_context&.fetch('mail_action'))
    end

    def email_delivery_mail_action
      framework_envelope.fetch(:mail_action)
    end

    def email_delivery_params
      framework_envelope.fetch(:params)
    end

    private

    # ActionMailer::MailDeliveryJob#perform owns this serialized argument contract.
    def framework_envelope
      mailer, mail_method, delivery_method, keywords = arguments
      decode_framework_envelope(mailer, mail_method, delivery_method, **keywords.symbolize_keys)
    end

    def decode_framework_envelope(mailer, mail_method, _delivery_method, args:, kwargs: nil, params: nil)
      raise ArgumentError, 'Invalid Action Mailer arguments' unless args.is_a?(Array) && (kwargs.nil? || kwargs.is_a?(Hash))

      { mail_action: "#{mailer}##{mail_method}", params: params || {} }
    end
  end
end
