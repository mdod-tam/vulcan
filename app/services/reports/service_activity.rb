# frozen_string_literal: true

module Reports
  class ServiceActivity
    attr_reader :period

    def initialize(period)
      @period = period
    end

    def appointments
      visits = Evaluation.status_completed.where(appointment_completed_at: period.range)
                         .pluck(:evaluator_id, :appointment_completed_at)
      sessions = trainings.pluck(:trainer_id, :completed_at, :duration_hours)
      {
        visits_by_month: period.monthly(visits.map { |_staff, date| [date, 1] }),
        visits_by_staff: by_staff(visits),
        hours_by_month: period.monthly(sessions.map { |_staff, date, hours| [date, hours] }),
        hours_by_staff: by_staff(sessions) { |rows| rows.sum(&:last) }
      }
    end

    def timing
      reports = submitted_reports.pluck(:evaluator_id, :report_submitted_at, :appointment_completed_at).group_by(&:first)
      names = StaffNames.for(reports.keys)
      {
        reports_by_month: reports.to_h do |staff, rows|
          [names.fetch(staff), period.monthly(rows.map { |_id, submitted, _visit| [submitted, 1] })]
        end,
        report_delays: report_delays(reports, names),
        evaluation_booking: booking_delay(Evaluation, ServiceDashboardSummary::EVALUATION),
        training_booking: booking_delay(TrainingSession, ServiceDashboardSummary::TRAINING)
      }
    end

    def devices
      recommendations = submitted_reports.joins(:recommended_products).distinct
                                         .group(:evaluator_id, 'products.id').count(:id)
      {
        recommended: named_products(recommendations),
        trained: named_products(trained_product_counts),
        repeat_training: named_products(repeat_training_counts)
      }
    end

    private

    def trainings
      TrainingSession.status_completed.where(completed_at: period.range)
    end

    def submitted_reports
      Evaluation.status_completed.where(report_submitted_at: period.range)
    end

    def by_staff(rows)
      grouped = rows.group_by(&:first)
      names = StaffNames.for(grouped.keys)
      grouped.to_h { |id, records| [names.fetch(id), block_given? ? yield(records) : records.size] }
             .sort_by { |name, count| [-count, name] }.to_h
    end

    def report_delays(reports, names)
      delays = reports.filter_map do |staff, rows|
        days = rows.filter_map do |_id, submitted, visit|
          (submitted - visit) / 1.day if visit && visit <= submitted
        end.sort
        [names.fetch(staff), Percentile.calculate(days, 0.9), days.size] if days.present?
      end
      delays.sort_by { |name, days, _count| [-days, name] }
    end

    def booking_delay(model, timings)
      ServiceDashboardSummary.new(model.all, timings:, now: period.now).average_scheduling_days(period.range)
    end

    def named_products(counts)
      staff = StaffNames.for(counts.keys.map(&:first))
      rows = Product.where(id: counts.keys.map(&:last).uniq).pluck(:id, :name, :manufacturer, :model_number)
      name_counts = rows.pluck(1).tally
      products = rows.to_h do |id, name, manufacturer, model|
        [id, name_counts.fetch(name) > 1 ? "#{name} (#{manufacturer} #{model})" : name]
      end
      counts.map { |(person, product), count| [staff.fetch(person), products.fetch(product), count] }
    end

    def trained_product_counts
      covered = trainings.where.not(product_trained_on_id: nil).pluck(:id, :trainer_id, :product_trained_on_id)
      linked = trained_equipment.pluck('training_sessions.id', 'training_sessions.trainer_id', 'equipment_items.product_id')
      (covered | linked).group_by { |_session, trainer, product| [trainer, product] }.transform_values(&:size)
    end

    def trained_equipment
      TrainingSessionEquipmentItem.joins(:equipment_item, :training_session).merge(trainings)
    end

    def repeat_training_counts
      trained_equipment.joins(training_session: :application).where(<<~SQL.squish, completed: TrainingSession.statuses.fetch('completed'))
        EXISTS (
          SELECT 1
          FROM training_session_equipment_items earlier_links
          JOIN training_sessions earlier_sessions ON earlier_sessions.id = earlier_links.training_session_id
          JOIN applications earlier_applications ON earlier_applications.id = earlier_sessions.application_id
          WHERE earlier_links.equipment_item_id = training_session_equipment_items.equipment_item_id
            AND earlier_applications.user_id = applications.user_id
            AND earlier_sessions.status = :completed AND earlier_sessions.completed_at < training_sessions.completed_at
        )
      SQL
                       .distinct.group('training_sessions.trainer_id', 'equipment_items.product_id').count('training_sessions.id')
    end
  end
end
