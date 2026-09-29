# frozen_string_literal: true

# For a job that sends an email itself. Captures the email controls when the job is queued and
# keeps them through retries, so the email is checked against the settings in force when it was
# requested rather than when a worker happens to run it.
module EmailDeliveryContextJob
  extend ActiveSupport::Concern

  included do
    attr_accessor :email_delivery_context

    # The catalog key of the email this job sends; a job may override the reader.
    class_attribute :email_delivery_mail_action, instance_writer: false

    # Rails stores ActiveJob::EnqueueError, but Solid Queue raises its own error for failed inserts.
    # Normalize both at the actual enqueue boundary, including writes deferred until commit.
    around_enqueue do |job, block|
      begin
        block.call
      rescue SolidQueue::Job::EnqueueError => e
        job.enqueue_error = e
        job.successfully_enqueued = false
      end

      if job.enqueue_error
        EmailDelivery::Outcome.record_enqueue_failure(job.enqueue_error, context: job.email_delivery_context,
                                                                         mail_action: job.email_delivery_mail_action)
      end
    end

    # A job run directly with perform_now was never queued, so it is checked like an immediate send.
    # A queued job that arrives without a context was queued before capture existed and is not sent.
    around_perform do |job, block|
      if job.enqueued_at.nil?
        job.email_delivery_context ||= EmailDelivery::Policy.capture(mail_action: job.email_delivery_mail_action,
                                                                     params: job.email_delivery_params)
      end
      EmailDelivery::Current.set(context: job.email_delivery_context, queued: true, denial_decision: nil) { block.call }
    end
  end

  # Rails defers enqueue callbacks until commit. Capture here while the caller's notification
  # context and the original control generations are still available; retries keep that capture.
  def enqueue(options = {})
    self.email_delivery_context ||= EmailDelivery::Policy.capture(mail_action: email_delivery_mail_action,
                                                                  params: email_delivery_params)
    super
  end

  # Mailer params the capture needs, such as a test send's template name.
  def email_delivery_params
    {}
  end

  def serialize
    super.merge('email_delivery_context' => email_delivery_context)
  end

  def deserialize(job_data)
    super
    self.email_delivery_context = job_data['email_delivery_context']
  end
end
