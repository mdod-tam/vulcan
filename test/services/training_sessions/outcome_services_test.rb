# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class OutcomeServicesTest < ActiveSupport::TestCase
    setup do
      @trainer = create(:trainer)
      @session = create(:training_session, :scheduled, trainer: @trainer, internal_notes: 'PRIVATE preparation', created_at: 2.days.ago)
      @application = @session.application
      @product = create(:product)
    end

    test 'early completion stores actual and submission times separately without replacing omitted private notes' do
      actual_time = 1.hour.ago
      result = nil
      assert_difference "Event.where(action: 'training_completed').count", 1 do
        result = CompleteService.new(@session, @trainer, completion_params.merge(completed_at: actual_time)).call
        assert result.success?, result.message
      end
      @session.reload
      assert @session.status_completed?
      assert_in_delta actual_time, @session.completed_at, 1.second
      assert_operator @session.report_submitted_at, :>, @session.completed_at
      assert_equal 'PRIVATE preparation', @session.internal_notes
      assert_equal 'We practised VoiceOver.', @session.constituent_summary
      assert_equal @trainer.id, @application.reload.assigned_trainer_id
      assert_not_includes Event.find_by!(action: 'training_completed', auditable: @session).metadata.to_json, 'PRIVATE'
    end

    test 'future actual completion and missing summaries fail without a saved report' do
      assert_no_difference 'Event.count' do
        result = CompleteService.new(@session, @trainer, completion_params.merge(completed_at: 1.hour.from_now)).call
        assert_not result.success?
      end
      assert @session.reload.status_scheduled?
      assert_equal 'PRIVATE preparation', @session.internal_notes
      assert_nil @session.report_submitted_at

      result = CompleteService.new(@session, @trainer, completion_params.merge(constituent_summary: '')).call
      assert_not result.success?
      assert @session.reload.status_scheduled?
    end

    test 'an explicitly submitted blank clears optional private notes at completion' do
      result = CompleteService.new(@session, @trainer, completion_params.merge(internal_notes: '')).call

      assert result.success?, result.message
      assert_equal '', @session.reload.internal_notes
    end

    test 'completion before request creation fails without saving report fields or an audit' do
      assert_no_difference 'Event.count' do
        result = CompleteService.new(@session, @trainer, completion_params.merge(completed_at: @session.created_at - 1.minute)).call
        assert_not result.success?
      end

      assert @session.reload.status_scheduled?
      assert_nil @session.constituent_summary
      assert_nil @session.report_submitted_at
    end

    test 'programming argument errors propagate and roll back the report instead of becoming form errors' do
      AuditEventService.stubs(:log).raises(ArgumentError, 'Programming defect in audit arguments')

      assert_no_difference 'Event.count' do
        error = assert_raises(ArgumentError) { CompleteService.new(@session, @trainer, completion_params).call }
        assert_equal 'Programming defect in audit arguments', error.message
      end
      assert @session.reload.status_scheduled?
      assert_nil @session.constituent_summary
      assert_nil @session.report_submitted_at
    end

    test 'a stale no-show cannot overwrite a completed report' do
      stale = TrainingSession.find(@session.id)
      result = CompleteService.new(@session, @trainer, completion_params).call
      assert result.success?, result.message

      assert_no_difference 'Event.count' do
        result = NoShowService.new(stale, @trainer, no_show_notes: 'Late stale form').call
        assert_not result.success?
      end
      assert @session.reload.status_completed?
      assert_nil @session.no_show_notes
    end

    test 'no-show requires a passed appointment and a private reason' do
      result = NoShowService.new(@session, @trainer, no_show_notes: 'PRIVATE absence').call
      assert_not result.success?
      travel_to 2.days.from_now do
        result = NoShowService.new(@session, @trainer, no_show_notes: '').call
        assert_not result.success?
        @session.reload
        result = NoShowService.new(@session, @trainer, no_show_notes: 'PRIVATE absence').call
        assert result.success?, result.message
      end
      assert @session.reload.status_no_show?
      assert_equal 'PRIVATE preparation', @session.internal_notes
      assert_not_includes Event.find_by!(action: 'training_no_show', auditable: @session).metadata.to_json, 'PRIVATE'
    end

    test 'requested appointments can be cancelled and ordinary cancellation retains coverage and private notes' do
      session = create(:training_session, internal_notes: 'PRIVATE scheduling context')
      result = CancelService.new(session, session.trainer,
                                 cancellation_reason: 'PRIVATE personal reason', cancellation_initiator: 'constituent').call

      assert result.success?, result.message
      assert session.reload.status_cancelled?
      assert session.cancellation_initiator_constituent?
      assert_equal session.trainer_id, session.application.reload.assigned_trainer_id
      assert_equal 'PRIVATE scheduling context', session.internal_notes
      event = Event.find_by!(action: 'training_cancelled', auditable: session)
      assert_equal session.trainer_id, event.user_id
      assert_equal 'constituent', event.metadata['cancellation_initiator']
      assert_not_includes event.metadata.to_json, 'PRIVATE'
    end

    test 'a trainer cannot falsely attribute cancellation to an administrator' do
      result = CancelService.new(@session, @trainer, cancellation_reason: 'Reason', cancellation_initiator: 'admin').call

      assert_not result.success?
      assert @session.reload.status_scheduled?
    end

    test 'recorded outcomes cannot be replaced by another named command' do
      result = CancelService.new(@session, @trainer, cancellation_reason: 'Requested cancellation', cancellation_initiator: 'constituent').call
      assert result.success?, result.message

      assert_no_difference 'Event.count' do
        assert_not CompleteService.new(@session, @trainer, completion_params).call.success?
        assert_not NoShowService.new(@session, @trainer, no_show_notes: 'Changed interpretation').call.success?
        assert_not CancelService.new(@session, @trainer, cancellation_reason: 'Replacement', cancellation_initiator: 'trainer').call.success?
      end
      assert @session.reload.status_cancelled?
      assert_equal 'Requested cancellation', @session.cancellation_reason
    end

    test 'completion stays available after the service window and quota close' do
      Policy.stubs(:max_training_sessions).returns(1)
      @application.update!(application_date: 5.years.ago.to_date)

      result = CompleteService.new(@session, @trainer, completion_params).call
      assert result.success?, result.message
      assert @session.reload.status_completed?
    end

    test 'reschedule requires a future changed date and remains truthful after the original start' do
      result = RescheduleService.new(@session, @trainer, scheduled_for: @session.scheduled_for,
                                                         reschedule_reason: 'Constituent requested a change').call
      assert_not result.success?
      @session.reload
      result = RescheduleService.new(@session, @trainer, scheduled_for: 3.days.from_now,
                                                         reschedule_reason: 'PRIVATE requested change', location: 'Library').call
      assert result.success?, result.message
      assert_equal 'PRIVATE preparation', @session.reload.internal_notes
      assert_not_includes Event.find_by!(action: 'training_rescheduled', auditable: @session).metadata.to_json, 'PRIVATE'

      travel_to 4.days.from_now do
        result = RescheduleService.new(@session, @trainer, scheduled_for: 2.days.from_now, reschedule_reason: 'Late change').call
        assert result.success?, result.message
        assert @session.reload.status_scheduled?
        assert_equal 'Late change', @session.reschedule_reason
      end
    end

    test 'removed trainer stale forms fail after locked reload' do
      stale = TrainingSession.find(@session.id)
      assert @application.unassign_trainer!(actor: create(:admin))
      assert_no_difference 'Event.count' do
        assert_not CompleteService.new(stale, @trainer, completion_params).call.success?
      end
      assert @session.reload.status_cancelled?
      assert_equal 'PRIVATE preparation', @session.internal_notes
    end

    test 'audit failure rolls back state and report fields' do
      invalid_event = Event.new
      invalid_event.errors.add(:base, 'Unavailable')
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(invalid_event))

      result = CompleteService.new(@session, @trainer, completion_params).call
      assert_not result.success?
      assert @session.reload.status_scheduled?
      assert_nil @session.constituent_summary
      assert_nil @session.report_submitted_at
    end

    private

    def completion_params
      { completed_at: 10.minutes.ago, constituent_summary: 'We practised VoiceOver.', summary_locale: 'en',
        duration_hours: '1.25', product_trained_on_id: @product.id }
    end
  end
end
