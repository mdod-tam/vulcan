# frozen_string_literal: true

module EmailDelivery
  # Mail jobs queued by a release before the email controls existed. They carry no captured
  # context, so none of them may acquire today's settings and send. Rollout reports them, then
  # removes them with durable intent and confirmation events; nothing about them is replayed.
  module LegacyMailJobs
    FRAMEWORK_MAIL_JOB = 'ActionMailer::MailDeliveryJob'
    CONTEXT_JOBS = %w[DisabilityCertificationEmailJob EmailDelivery::MailDeliveryJob].freeze
    AUDIT_ACTION = 'email_delivery_legacy_job_removed'
    INTENT_ACTION = 'email_delivery_legacy_job_removal_requested'
    OPERATION_INDEX = 'index_events_on_legacy_mail_removal_operation'

    module_function

    def pending
      SolidQueue::Job.where(finished_at: nil, class_name: [FRAMEWORK_MAIL_JOB, *CONTEXT_JOBS]).select do |job|
        job.class_name == FRAMEWORK_MAIL_JOB || job.arguments.to_h.dig('email_delivery_context', 'version') != Policy::CONTEXT_VERSION
      end
    end

    def report
      jobs = pending
      unconfirmed = unfinished_intents.count
      return 'No legacy mail jobs are waiting.' if jobs.empty? && unconfirmed.zero?

      counts = jobs.group_by { |job| mail_action_for(job) }.transform_values(&:size)
      (["#{jobs.size} legacy mail jobs are waiting:"] + counts.sort.map { |action, count| "  #{action}: #{count}" } +
        ["#{unconfirmed} legacy mail job removals await confirmation."]).join("\n")
    end

    # Workers must be stopped. Intent commits before the independent queue deletion; a later run
    # confirms unfinished intents even when their jobs are already gone. Audits retain job identity
    # and mail action without the serialized delivery arguments.
    def remove!(actor:)
      raise ArgumentError, 'Legacy mail cleanup must run outside an application transaction' if ActiveRecord::Base.current_transaction.open?

      intents = unfinished_intents.index_by { |event| event.metadata.fetch('operation_id') }
      pending.each do |job|
        operation_id = "legacy-mail-job-removal:#{job.id}:#{job.active_job_id}"
        intents[operation_id] ||= record_event(action: INTENT_ACTION, actor: actor,
                                               metadata: { operation_id: operation_id, solid_queue_job_id: job.id,
                                                           active_job_id: job.active_job_id, job_class: job.class_name,
                                                           mail_action: mail_action_for(job) }.compact)
      end
      intents.values.count { |intent| confirm_removal(intent, actor: actor) }
    end

    def unfinished_intents
      Event.where(action: INTENT_ACTION).where(<<~SQL.squish, action: AUDIT_ACTION).order(:id)
        NOT EXISTS (
          SELECT 1 FROM events AS confirmations
          WHERE confirmations.action = :action
            AND confirmations.metadata->>'operation_id' = events.metadata->>'operation_id'
        )
      SQL
    end
    private_class_method :unfinished_intents

    def confirm_removal(intent, actor:)
      metadata = intent.metadata
      return false if Event.where(action: AUDIT_ACTION).with_metadata(:operation_id, metadata.fetch('operation_id')).exists?

      outcome = SolidQueue::Job.transaction do
        job = SolidQueue::Job.where(id: metadata.fetch('solid_queue_job_id'), class_name: metadata.fetch('job_class'),
                                    active_job_id: metadata['active_job_id']).lock.first
        if job
          job.destroy!
          'deleted_now'
        else
          'already_absent'
        end
      end
      record_event(action: AUDIT_ACTION, actor: actor,
                   metadata: metadata.slice('operation_id', 'solid_queue_job_id', 'active_job_id', 'job_class', 'mail_action')
                                     .merge('removal_intent_event_id' => intent.id, 'removal_outcome' => outcome))
      true
    end
    private_class_method :confirm_removal

    def record_event(action:, actor:, metadata:)
      Event.transaction(requires_new: true) do
        AuditEventService.log(action: action, actor: actor, metadata: metadata)
      end
    rescue ActiveRecord::RecordNotUnique => e
      constraint = e.cause&.result&.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
      raise unless constraint == OPERATION_INDEX

      operation_id = metadata[:operation_id] || metadata.fetch('operation_id')
      Event.where(action: action).with_metadata(:operation_id, operation_id).sole
    end
    private_class_method :record_event

    def mail_action_for(job)
      return job.class_name unless job.class_name == FRAMEWORK_MAIL_JOB

      mailer, method = Array(job.arguments.to_h['arguments']).first(2)
      "#{mailer}##{method}"
    end
  end
end
