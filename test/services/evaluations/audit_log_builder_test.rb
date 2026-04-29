# frozen_string_literal: true

require 'test_helper'

module Evaluations
  class AuditLogBuilderTest < ActiveSupport::TestCase
    setup do
      @evaluator = create(:evaluator)
      @application = create(:application, :old_enough_for_new_application)
      @evaluation = create(:evaluation, evaluator: @evaluator, application: @application, constituent: @application.user)
      @other_application = create(:application, :old_enough_for_new_application)
    end

    test 'returns empty array for nil evaluation' do
      assert_empty AuditLogBuilder.new(nil).build
    end

    test 'includes events owned by the evaluation' do
      event = Event.create!(
        user: @evaluator,
        action: 'evaluation_scheduled',
        auditable: @evaluation,
        metadata: {}
      )

      assert_includes AuditLogBuilder.new(@evaluation).build, event
    end

    test 'includes events that reference the evaluation in metadata' do
      event = Event.create!(
        user: @evaluator,
        action: 'evaluation_completed',
        metadata: { evaluation_id: @evaluation.id.to_s }
      )

      assert_includes AuditLogBuilder.new(@evaluation).build, event
    end

    test 'includes scoped application fulfillment events' do
      bids_event = Event.create!(
        user: @evaluator,
        action: 'equipment_bids_sent',
        auditable: @application,
        metadata: { date: Date.current }
      )
      po_event = Event.create!(
        user: @evaluator,
        action: 'equipment_po_sent',
        auditable: @application,
        metadata: { date: Date.current }
      )

      logs = AuditLogBuilder.new(@evaluation).build

      assert_includes logs, bids_event
      assert_includes logs, po_event
    end

    test 'excludes unrelated application events' do
      unrelated_app_event = Event.create!(
        user: @evaluator,
        action: 'equipment_bids_sent',
        auditable: @other_application,
        metadata: { date: Date.current }
      )
      unrelated_action = Event.create!(
        user: @evaluator,
        action: 'voucher_assigned',
        auditable: @application,
        metadata: {}
      )

      logs = AuditLogBuilder.new(@evaluation).build

      assert_not_includes logs, unrelated_app_event
      assert_not_includes logs, unrelated_action
    end

    test 'deduplicates and sorts newest first' do
      older = Event.create!(
        user: @evaluator,
        action: 'evaluation_scheduled',
        auditable: @evaluation,
        metadata: { evaluation_id: @evaluation.id },
        created_at: 2.hours.ago
      )
      newer = Event.create!(
        user: @evaluator,
        action: 'equipment_po_sent',
        auditable: @application,
        metadata: { date: Date.current },
        created_at: 1.hour.ago
      )

      logs = AuditLogBuilder.new(@evaluation).build
      older_event_count = logs.count { |log| log.id == older.id }

      assert_equal 1, older_event_count
      assert_operator logs.index(newer), :<, logs.index(older)
    end
  end
end
