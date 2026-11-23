# frozen_string_literal: true

require 'test_helper'

module Reports
  class ServiceActivityTest < ActiveSupport::TestCase
    test 'uses appointment, report, and booking dates for their own measures' do
      travel_to Time.zone.local(2026, 8, 20, 12) do
        appointment = create(:evaluation, :completed, appointment_completed_at: Time.zone.local(2026, 6, 29),
                                                      report_submitted_at: Time.zone.local(2026, 7, 3))
        admin = create(:admin)
        Event.create!(user: admin, auditable: appointment.application, action: 'evaluator_assigned',
                      metadata: { operation_id: appointment.assignment_operation_id }, created_at: Time.zone.local(2026, 5, 31))
        Event.create!(user: appointment.evaluator, auditable: appointment, action: 'evaluation_scheduled', created_at: Time.zone.local(2026, 6, 2))

        report = ServiceActivity.new(Period.new(3))
        name = appointment.evaluator.full_name
        assert_equal [1, 0, 0], report.appointments.fetch(:visits_by_month)
        assert_equal({ name => 1 }, report.appointments.fetch(:visits_by_staff))
        assert_equal({ name => [0, 1, 0] }, report.timing.fetch(:reports_by_month))
        assert_equal [[name, 4.0, 1]], report.timing.fetch(:report_delays)
        assert_equal 2.0, report.timing.fetch(:evaluation_booking)
        assert_nil report.timing.fetch(:training_booking)
        assert_equal appointment.recommended_products.size, report.devices.fetch(:recommended).sum(&:last)
      end
    end

    test 'counts repeat training only for a recorded unit covered earlier with the same person' do
      travel_to Time.zone.local(2026, 8, 20, 12) do
        equipment = create(:equipment_item)
        other_unit = create(:equipment_item, application: equipment.application, product: equipment.product)
        trainer = create(:trainer)
        first = create(:training_session, :completed, application: equipment.application, trainer:, product_trained_on: equipment.product,
                                                      completed_at: Time.zone.local(2026, 5, 10))
        first.equipment_items << equipment
        repeat_session = create(:training_session, :completed, application: equipment.application, trainer:, product_trained_on: equipment.product,
                                                               completed_at: Time.zone.local(2026, 7, 10), duration_hours: 1.5)
        repeat_session.equipment_items << equipment
        new_session = create(:training_session, :completed, application: equipment.application, trainer:, product_trained_on: equipment.product,
                                                            completed_at: Time.zone.local(2026, 7, 11), duration_hours: 2)
        new_session.equipment_items << other_unit

        report = ServiceActivity.new(Period.new(3))
        assert_equal [0, 3.5, 0], report.appointments.fetch(:hours_by_month)
        assert_equal [[trainer.full_name, equipment.product.name, 2]], report.devices.fetch(:trained)
        assert_equal [[trainer.full_name, equipment.product.name, 1]], report.devices.fetch(:repeat_training)
      end
    end
  end
end
