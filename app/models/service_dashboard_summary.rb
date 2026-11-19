# frozen_string_literal: true

# The two professional dashboards share recorded assignment, scheduling and actual-visit clocks.
class ServiceDashboardSummary
  Summary = Data.define(:count, :oldest, :average_days, :sample_count, :unknown_dates)
  Entry = Data.define(:record, :application, :entered_at, :days, :clock, :practitioner)
  TRAINING = { assignment: %w[trainer_assigned trainer_reassigned].freeze,
               scheduling: %w[training_scheduled training_rescheduled training_followup_scheduled].freeze,
               completion: :completed_at, practitioner: :trainer }.freeze
  EVALUATION = { assignment: %w[evaluator_assigned evaluator_reassigned].freeze,
                 scheduling: %w[evaluation_scheduled evaluation_rescheduled].freeze,
                 completion: :appointment_completed_at, practitioner: :evaluator }.freeze

  def initialize(records, timings:, pending_requests: Application.none, now: Time.current)
    @records = records.except(:order, :includes, :preload, :eager_load)
    @timings = timings
    @pending_requests = pending_requests
    @now = now
  end

  def call
    {
      requested: requested_summary,
      scheduled: summarize(@records.where(status: %i[scheduled confirmed]), scheduled_date,
                           clock: :scheduled, statistics: completion_statistics)
    }
  end

  private

  def table
    @records.klass.arel_table
  end

  def assignment_date
    events = Event.arel_table
    operation = Arel::Nodes::InfixOperation.new('->>', events[:metadata], Arel::Nodes.build_quoted('operation_id'))
    subject = events[:auditable_type].eq('Application').and(events[:auditable_id].eq(table[:application_id]))
    subject = subject.or(events[:auditable_type].eq(@records.klass.base_class.name).and(events[:auditable_id].eq(table[:id])))
    query = Event.where(action: @timings.fetch(:assignment), created_at: ..@now).where(subject)
                 .where(operation.eq(table[:assignment_operation_id])).select(events[:created_at].maximum)
    Arel::Nodes::Grouping.new(query.arel.ast)
  end

  def scheduling_events
    Event.where(auditable_type: @records.klass.base_class.name, action: @timings.fetch(:scheduling), created_at: ..@now)
         .where(Event.arel_table[:auditable_id].eq(table[:id]))
  end

  def scheduled_date
    Arel::Nodes::Grouping.new(scheduling_events.select(Event.arel_table[:created_at].maximum).arel.ast)
  end

  def requested_summary
    result = summarize(@records.where(status: :requested), assignment_date, clock: :assignment, statistics: scheduling_statistics)
    request = @pending_requests.includes(:user, :assigned_trainer).order(:training_requested_at, :id).first
    entry = request && Entry.new(record: nil, application: request, entered_at: request.training_requested_at,
                                 days: Equipment::WaitTime.days_since(request.training_requested_at, now: @now), clock: :request,
                                 practitioner: request.assigned_trainer)
    oldest = [result.oldest, entry].compact.min_by { |row| [row.entered_at, row.application.id] }
    Summary.new(count: result.count + @pending_requests.count, oldest:, average_days: result.average_days,
                sample_count: result.sample_count, unknown_dates: result.unknown_dates)
  end

  def summarize(records, entered_at, clock:, statistics:)
    dated = records.where(entered_at.not_eq(nil))
    record = dated.includes({ application: :user }, @timings.fetch(:practitioner)).select(table[Arel.star], entered_at.as('queue_entered_at'))
                  .order(entered_at.asc, table[:id].asc).first
    oldest = if record
               date = record.queue_entered_at
               Entry.new(record:, application: record.application, entered_at: date,
                         days: Equipment::WaitTime.days_since(date, now: @now), clock:, practitioner: record.public_send(@timings.fetch(:practitioner)))
             end
    count = records.count
    sample_count, average_seconds = statistics
    Summary.new(count:, oldest:, average_days: average_seconds && (average_seconds.to_f / 1.day).round(1),
                sample_count:, unknown_dates: count - dated.count)
  end

  def scheduling_statistics
    events = Event.arel_table
    scheduled = scheduling_events.where(events[:created_at].gteq(assignment_date)).select(events[:created_at].minimum).arel
    rows = @records.select(assignment_date.as('assigned_at'), scheduled.as('scheduled_at'))
    dates = Arel::Table.new(:recorded_service_waits)
    @records.klass.unscoped.from(rows, :recorded_service_waits).where(dates[:assigned_at].not_eq(nil).and(dates[:scheduled_at].not_eq(nil)))
            .pick(Arel.sql('COUNT(*)'), Arel.sql('AVG(EXTRACT(EPOCH FROM (scheduled_at - assigned_at)))'))
  end

  def completion_statistics
    completed = table[@timings.fetch(:completion)]
    scheduled = scheduling_events.where(Event.arel_table[:created_at].lteq(completed)).select(Event.arel_table[:created_at].maximum).arel
    rows = @records.where(status: :completed).where(completed.lteq(@now)).select(completed.as('completed_at'), scheduled.as('scheduled_at'))
    dates = Arel::Table.new(:recorded_service_waits)
    @records.klass.unscoped.from(rows, :recorded_service_waits).where(dates[:scheduled_at].not_eq(nil))
            .pick(Arel.sql('COUNT(*)'), Arel.sql('AVG(EXTRACT(EPOCH FROM (completed_at - scheduled_at)))'))
  end
end
