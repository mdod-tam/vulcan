# frozen_string_literal: true

module EmailDelivery
  # The application's mail delivery job. It captures the delivery context when the email is
  # queued and carries it through retries, so a worker checks the controls as they stood when
  # the email was requested rather than granting fresh authorization.
  class MailDeliveryJob < ActionMailer::MailDeliveryJob
    include EmailDeliveryContextJob

    # Queue only after the caller's transaction commits.
    self.enqueue_after_transaction_commit = true

    def email_delivery_mail_action
      mailer, mail_method = arguments
      "#{mailer}##{mail_method}"
    end

    def email_delivery_params
      options = arguments[3]
      (options.is_a?(Hash) && (options[:params] || options['params'])) || {}
    end
  end
end
