# frozen_string_literal: true

module EmailDelivery
  # Mail jobs queued by a release before the email controls existed. They carry no captured
  # context, so none of them may acquire today's settings and send. Rollout reports them, then
  # removes them with an audit record each; nothing about them is replayed.
  module LegacyMailJobs
    FRAMEWORK_MAIL_JOB = 'ActionMailer::MailDeliveryJob'
    CONTEXT_JOBS = %w[MedicalCertificationEmailJob EmailDelivery::MailDeliveryJob].freeze
    AUDIT_ACTION = 'email_delivery_legacy_job_removed'

    module_function

    def pending
      SolidQueue::Job.where(finished_at: nil, class_name: [FRAMEWORK_MAIL_JOB, *CONTEXT_JOBS]).select do |job|
        job.class_name == FRAMEWORK_MAIL_JOB || job.arguments.to_h.dig('email_delivery_context', 'version') != Policy::CONTEXT_VERSION
      end
    end

    def report
      jobs = pending
      return 'No legacy mail jobs are waiting.' if jobs.empty?

      counts = jobs.group_by { |job| mail_action_for(job) }.transform_values(&:size)
      (["#{jobs.size} legacy mail jobs are waiting:"] + counts.sort.map { |action, count| "  #{action}: #{count}" }).join("\n")
    end

    # Removes each job and records what it was, without its arguments (they hold recipient data).
    def remove!(actor:)
      pending.each do |job|
        mail_action = mail_action_for(job)
        job.destroy!
        Event.create!(user: actor, action: AUDIT_ACTION,
                      metadata: { solid_queue_job_id: job.id, job_class: job.class_name, mail_action: mail_action })
      end.size
    end

    def mail_action_for(job)
      return job.class_name unless job.class_name == FRAMEWORK_MAIL_JOB

      mailer, method = Array(job.arguments.to_h['arguments']).first(2)
      "#{mailer}##{method}"
    end
  end
end
