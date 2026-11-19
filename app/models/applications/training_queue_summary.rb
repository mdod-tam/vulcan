# frozen_string_literal: true

module Applications
  class TrainingQueueSummary
    Summary = Data.define(:count, :oldest, :average_assignment_days, :assignment_sample_count, :unknown_dates)
    Entry = Data.define(:application, :disability_labels, :entered_at, :days)

    def initialize(applications: Application.awaiting_trainer_assignment, now: Time.current)
      @applications = applications
      @now = now
    end

    def call
      applications = @applications
      entered_at = Application.arel_table[:training_requested_at]
      dated = applications.where(entered_at.not_eq(nil))
      oldest = dated.includes(:user).select(Application.arel_table[Arel.star], entered_at.as('training_queue_entered_at'))
                    .order(entered_at.asc, :id).first
      count = applications.count
      sample_count, average_seconds = assignment_statistics
      Summary.new(count:, oldest: oldest && build_entry(oldest),
                  average_assignment_days: average_seconds && (average_seconds.to_f / 1.day).round(1),
                  assignment_sample_count: sample_count, unknown_dates: count - dated.count)
    end

    private

    def build_entry(application)
      entered_at = application.training_queue_entered_at
      labels = application.program_disability_groups.filter_map { |group| Product::PROGRAM_GROUPS[group] }
      Entry.new(application:, disability_labels: labels, entered_at:, days: Equipment::WaitTime.days_since(entered_at, now: @now))
    end

    # The first assignment after the current recorded request measures an actual assignment, not pending age.
    def assignment_statistics
      applications = Application.arel_table
      events = Event.arel_table
      assignment = Event.where(auditable_type: Application.base_class.name, action: 'trainer_assigned', created_at: ..@now)
                        .where(events[:auditable_id].eq(applications[:id]))
                        .where(events[:created_at].gteq(applications[:training_requested_at]))
                        .select(events[:created_at].minimum).arel
      requests = Application.where.not(training_requested_at: nil)
                            .select(applications[:training_requested_at].as('requested_at'), assignment.as('assigned_at'))
      rows = Arel::Table.new(:training_assignment_waits)
      Application.unscoped.from(requests, :training_assignment_waits).where(rows[:assigned_at].not_eq(nil))
                 .pick(Arel.sql('COUNT(*)'), Arel.sql('AVG(EXTRACT(EPOCH FROM (assigned_at - requested_at)))'))
    end
  end
end
