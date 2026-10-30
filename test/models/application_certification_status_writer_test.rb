# frozen_string_literal: true

require 'test_helper'

# Application#transition_disability_certification_status! is the one writer of the certification status.
# The service tests cover each flow's own metadata and notifications; these cover the writer's contract.
class ApplicationCertificationStatusWriterTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @application = create(:application, :in_progress)
  end

  test 'moves the status, its history row, and its audit event together' do
    freeze_time do
      change = @application.transition_disability_certification_status!(
        :received, actor: @admin, attributes: { disability_certification_verified_by_id: @admin.id },
                   metadata: { submission_method: 'secure_form' }
      )

      assert_equal 'received', @application.reload.disability_certification_status
      assert_equal @admin.id, @application.disability_certification_verified_by_id
      assert_equal [@application.id, 'not_requested', 'received', @admin.id],
                   [change.application_id, change.from_status, change.to_status, change.user_id]
      assert_includes @application.status_changes.disability_certification, change
      assert_equal %w[disability_certification secure_form], change.metadata.values_at('change_type', 'submission_method')

      event = Event.find_by!(action: 'disability_certification_status_changed', auditable: @application)
      assert_equal @admin, event.user
      assert_equal ['not_requested', 'received', 'disability_certification', @application.id],
                   event.metadata.values_at('old_status', 'new_status', 'change_type', 'application_id')
      assert_equal "disability-certification-status-change-#{change.id}", event.metadata['operation_id']
    end
  end

  test 'a repeat of the current status still records a history row and an audit event' do
    2.times do |index|
      @application.transition_disability_certification_status!(:rejected, actor: @admin, notes: "Rejection #{index}")
    end

    recorded = @application.status_changes.disability_certification.order(:id).map { |change| [change.from_status, change.to_status] }
    assert_equal [%w[not_requested rejected], %w[rejected rejected]], recorded
    assert_equal 2, Event.where(action: 'disability_certification_status_changed', auditable: @application).count
  end

  test 'notes go to the history row only' do
    change = @application.transition_disability_certification_status!(:rejected, actor: @admin, notes: 'Internal note')

    assert_equal 'Internal note', change.notes
    assert_equal 'Internal note', change.metadata['notes']
    event = Event.find_by!(action: 'disability_certification_status_changed', auditable: @application)
    assert_not event.metadata.key?('notes')
  end

  test 'a caller names the audit action for request flows' do
    @application.transition_disability_certification_status!(:requested, actor: @admin, action: 'disability_certification_requested')

    assert Event.exists?(action: 'disability_certification_requested', auditable: @application)
    assert_not Event.exists?(action: 'disability_certification_status_changed', auditable: @application)
  end

  test 'a failed audit event rolls back the status and its history row' do
    AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

    assert_no_difference 'ApplicationStatusChange.count' do
      assert_raises(ActiveRecord::RecordInvalid) do
        @application.transition_disability_certification_status!(:approved, actor: @admin)
      end
    end

    assert_equal 'not_requested', @application.reload.disability_certification_status
  end

  test 'an actor is required and nothing changes without one' do
    assert_raises(ArgumentError) { @application.transition_disability_certification_status!(:approved, actor: nil) }

    assert_equal 'not_requested', @application.reload.disability_certification_status
    assert_empty @application.status_changes.disability_certification
  end

  test 'an approved proof with no attachment does not block a certification status change' do
    @application.update_columns(id_proof_status: Application.id_proof_statuses[:approved])

    @application.transition_disability_certification_status!(:received, actor: @admin)

    assert_equal 'received', @application.reload.disability_certification_status
  end
end
