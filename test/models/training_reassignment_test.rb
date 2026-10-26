# frozen_string_literal: true

require 'test_helper'

class TrainingReassignmentTest < ActiveSupport::TestCase
  setup do
    Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
    load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
    @admin = create(:admin)
    @trainer = create(:trainer)
    @replacement = create(:trainer)
    @application = create(:application, status: :approved, application_date: Date.current, assigned_trainer: @trainer)
    @no_show = create(:training_session, :no_show, application: @application, trainer: @trainer, internal_notes: 'Missed once')
    @scheduled = create(:training_session, :scheduled, application: @application, trainer: @trainer, location: 'Agreed library room',
                                                       internal_notes: 'Interpreter arrangements')
  end

  def reassign(trainer = @replacement, actor: @admin, version: @application.training_assignment_version)
    @application.reassign_trainer!(trainer, actor: actor, expected_version: version)
  end

  test 'transfers every open row and the coverage, keeping schedules, outcomes and notes' do
    before = [@no_show, @scheduled].to_h { |session| [session.id, session.attributes.except('trainer_id', 'updated_at', 'assignment_operation_id')] }
    completed = create(:training_session, :completed, application: @application, trainer: @trainer)
    previous_operations = [@no_show, @scheduled].map(&:assignment_operation_id)

    assert_difference -> { Event.where(action: 'trainer_reassigned').count }, 1 do
      assert reassign
    end

    assert_equal @replacement.id, @application.reload.assigned_trainer_id
    [@no_show, @scheduled].each do |session|
      assert_equal @replacement.id, session.reload.trainer_id
      assert_equal before[session.id], session.attributes.except('trainer_id', 'updated_at', 'assignment_operation_id')
    end
    assert_equal @trainer.id, completed.reload.trainer_id
    assert_equal 1, [@no_show, @scheduled].map(&:assignment_operation_id).uniq.size
    assert_empty previous_operations & [@scheduled.assignment_operation_id]

    event = Event.find_by!(action: 'trainer_reassigned', auditable: @application)
    assert_equal @admin.id, event.user_id
    assert_equal @scheduled.assignment_operation_id, event.metadata['operation_id']
    assert_equal [@trainer.id], event.metadata['previous_trainer_ids']
    assert_equal [@no_show.id, @scheduled.id], event.metadata['training_session_ids']
    assert_equal 2, @application.training_notification_outcomes.size
    assert(@application.training_notification_outcomes.none?(&:warning?))
  end

  test 'queues one notice for the new trainer and one for the constituent after commit' do
    assert_difference -> { Notification.where(action: 'trainer_reassigned', recipient: @replacement).count }, 1 do
      assert_difference -> { Notification.where(action: 'training_trainer_changed', recipient: @application.user).count }, 1 do
        assert reassign
      end
    end

    metadata = Notification.find_by!(action: 'trainer_reassigned').metadata
    assert_equal @scheduled.reload.assignment_operation_id, metadata['operation_id']
  end

  test 'refuses when no open training remains, without audit or notices' do
    [@no_show, @scheduled].each { |session| session.update_columns(status: TrainingSession.statuses[:completed]) }
    version = @application.training_assignment_version

    assert_no_difference ['Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs { assert_equal false, reassign(version: version) }
    end

    assert_equal ['There is no open training to transfer.'], @application.errors[:base]
    assert_equal @trainer.id, @application.reload.assigned_trainer_id
  end

  test 'refuses stale coverage instead of overwriting a different assignment' do
    version = @application.training_assignment_version
    third = create(:trainer)
    @scheduled.update!(trainer: third)

    assert_no_difference ['Event.count', 'Notification.count'] do
      assert_equal false, reassign(version: version)
    end

    assert_equal ['Training assignments changed. Review the current assignment and try again.'], @application.errors[:base]
    assert_equal third.id, @scheduled.reload.trainer_id
    assert_equal @trainer.id, @no_show.reload.trainer_id
  end

  test 'refuses a non-administrator, an ineligible replacement, and an expired service window' do
    assert_equal false, reassign(actor: @trainer)
    assert_equal ['Only an administrator can reassign a trainer.'], @application.errors[:base]

    assert_equal false, reassign(create(:evaluator))
    assert_equal ['Select an active trainer.'], @application.errors[:base]

    @application.update!(application_date: 4.years.ago.to_date)
    assert_equal false, reassign
    assert_equal [I18n.t('activerecord.errors.models.application.attributes.base.training_service_window')], @application.errors[:base]
    assert_equal [@trainer.id], [@no_show, @scheduled].map { |session| session.reload.trainer_id }.uniq
  end

  test 'transferring to the current assignee is a no-op without audit or notices' do
    assert_no_difference ['Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs { assert reassign(@trainer) }
    end
  end

  test 'recovers work from a former trainer who is no longer eligible, and cancellation still works for them' do
    other = create(:application, status: :approved, application_date: Date.current, assigned_trainer: @trainer)
    session = create(:training_session, :scheduled, application: other, trainer: @trainer)
    @trainer.update!(status: :suspended)

    assert reassign
    assert_equal @replacement.id, @scheduled.reload.trainer_id

    assert other.unassign_trainer!(actor: @admin, reason: 'Coverage ended')
    assert session.reload.status_cancelled?
  end

  test 'an audit failure rolls back the transfer without notices' do
    invalid_event = Event.new
    invalid_event.errors.add(:base, 'Audit record unavailable')
    AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(invalid_event))
    attributes = [@no_show, @scheduled].map { |session| session.reload.attributes }

    assert_no_difference ['Event.count', 'Notification.count'] do
      assert_no_enqueued_jobs { assert_equal false, reassign }
    end

    assert_equal(attributes, [@no_show, @scheduled].map { |session| session.reload.attributes })
    assert_equal @trainer.id, @application.reload.assigned_trainer_id
  end
end
