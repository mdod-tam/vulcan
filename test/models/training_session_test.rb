# frozen_string_literal: true

require 'test_helper'

class TrainingSessionTest < ActiveSupport::TestCase
  test 'requested appointments do not need an agreed date or a report' do
    session = build(:training_session)

    assert session.valid?, session.errors.full_messages.to_sentence
    assert_nil session.scheduled_for
    assert_nil session.completed_at
  end

  test 'scheduled appointments require a future agreed date' do
    session = build(:training_session, :scheduled, scheduled_for: nil)
    assert_not session.valid?
    assert_includes session.errors[:scheduled_for], "can't be blank"

    session.scheduled_for = 1.hour.ago
    assert_not session.valid?
    assert_includes session.errors[:scheduled_for], 'must be in the future'
  end

  test 'trainer capability is required while administrators can train' do
    session = build(:training_session, trainer: create(:evaluator))
    assert_not session.valid?
    assert_includes session.errors[:trainer], 'must be a trainer'

    session.trainer = create(:admin)
    assert session.valid?, session.errors.full_messages.to_sentence
  end

  test 'completion requires a deliberate summary language product actual time and positive duration' do
    session = build(:training_session, :completed, constituent_summary: nil, summary_locale: nil,
                                                   product_trained_on: nil, completed_at: nil, duration_hours: 0)

    assert_not session.valid?
    %i[constituent_summary summary_locale product_trained_on completed_at duration_hours].each do |attribute|
      assert session.errors[attribute].any?, "Missing error on #{attribute}"
    end
    assert_nil session.completed_at, 'validation must not invent an occurrence time'
  end

  test 'internal notes are optional and do not supply the shared summary' do
    session = build(:training_session, :completed, internal_notes: nil)
    assert session.valid?, session.errors.full_messages.to_sentence

    session.internal_notes = 'Private observations'
    session.constituent_summary = ' '
    assert_not session.valid?
    assert_includes session.errors[:constituent_summary], "can't be blank"
  end

  test 'completion rejects future actual time while allowing an early visit' do
    session = build(:training_session, :completed, scheduled_for: 1.week.from_now, completed_at: 1.hour.ago)
    assert session.valid?, session.errors.full_messages.to_sentence

    session.completed_at = 1.hour.from_now
    assert_not session.valid?
    assert_includes session.errors[:completed_at], 'cannot be in the future'
  end

  test 'completion language must be supported' do
    session = build(:training_session, :completed, summary_locale: 'invented')

    assert_not session.valid?
    assert session.errors[:summary_locale].any?
  end

  test 'completion cannot precede request creation even when it precedes the planned appointment' do
    created_at = 2.days.ago
    session = build(:training_session, :completed, created_at: created_at, completed_at: created_at - 1.minute)

    assert_not session.valid?
    assert_includes session.errors[:completed_at], I18n.t('training_rules.completion_before_creation')

    session.completed_at = created_at
    assert session.valid?, session.errors.full_messages.to_sentence
  end

  test 'only one unresolved appointment is permitted even below quota' do
    Policy.stubs(:max_training_sessions).returns(3)
    existing = create(:training_session, :scheduled)
    second = build(:training_session, application: existing.application, trainer: existing.trainer)

    assert_not second.valid?
    assert_includes second.errors[:base], 'Record the outcome of the open appointment first.'
  end

  test 'the database rejects a second unresolved appointment' do
    existing = create(:training_session, :scheduled)
    duplicate = existing.attributes.except('id').merge('status' => TrainingSession.statuses[:requested], 'scheduled_for' => nil)

    assert_raises(ActiveRecord::RecordNotUnique) do
      TrainingSession.transaction(requires_new: true) { TrainingSession.insert_all!([duplicate]) }
    end
    assert_equal [existing.id], existing.application.training_sessions.assigned_or_scheduled.pluck(:id)
  end

  test 'the final reserved slot remains editable and can be closed at quota' do
    Policy.stubs(:max_training_sessions).returns(1)
    session = create(:training_session, :scheduled)

    session.internal_notes = 'Preparation retained'
    assert session.valid?, session.errors.full_messages.to_sentence
    session.assign_attributes(status: :cancelled, cancellation_reason: 'Requested cancellation')
    assert session.valid?, session.errors.full_messages.to_sentence
  end

  test 'historical outcomes cannot reopen or replace another recorded outcome' do
    session = create(:training_session, :cancelled)
    session.assign_attributes(status: :scheduled, scheduled_for: 1.day.from_now)
    assert_not session.valid?
    assert_includes session.errors[:base], I18n.t('activerecord.errors.models.training_session.attributes.base.historical_session_reopen')

    session.assign_attributes(status: :no_show, no_show_notes: 'Later interpretation')
    assert_not session.valid?
    assert_includes session.errors[:base], 'A recorded appointment outcome cannot be replaced.'
  end

  test 'appointment ordinals and prior reports use deterministic creation order' do
    Policy.stubs(:max_training_sessions).returns(5)
    application = create(:application, :approved, application_date: Date.current)
    trainer = create(:trainer)
    timestamp = 2.days.ago
    first = create(:training_session, :completed, application: application, trainer: trainer, created_at: timestamp)
    second = create(:training_session, :completed, application: application, trainer: trainer, created_at: timestamp)
    current = create(:training_session, application: application, trainer: trainer, created_at: timestamp)
    create(:training_session, :completed)

    assert_equal [1, 2, 3], [first, second, current].map(&:appointment_number)
    assert_equal [second.id, first.id], current.previous_completed_sessions.pluck(:id)
  end
end
