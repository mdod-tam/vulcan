# frozen_string_literal: true

module EmailDelivery
  # The application's mail delivery job. It captures the delivery context when the email is
  # queued and carries it through retries, so a worker checks the controls as they stood when
  # the email was requested rather than granting fresh authorization.
  class MailDeliveryJob < ActionMailer::MailDeliveryJob
    include EmailDeliveryContextJob

    # Queue only after the caller's transaction commits.
    self.enqueue_after_transaction_commit = true

    before_enqueue :stop_email_only_delivery

    def email_delivery_mail_action
      mailer, mail_method = arguments
      "#{mailer}##{mail_method}"
    end

    def email_delivery_params
      options = arguments[3]
      (options.is_a?(Hash) && (options[:params] || options['params'])) || {}
    end

    private

    # An email-only action has no letter route to preserve, so a denied one is not queued at all.
    # Actions that may print still run, and the final check stops only their email.
    def stop_email_only_delivery
      mail_action = email_delivery_mail_action
      return unless Catalog.mail_action(mail_action)&.email_only?

      decision = Policy.verify_delivery(mail_action, email_delivery_context)
      return if decision.allowed?

      Outcome.record_not_sent(decision, context: email_delivery_context, mail_action: mail_action)
      throw :abort
    end
  end
end
