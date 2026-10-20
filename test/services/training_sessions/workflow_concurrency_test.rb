# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class WorkflowConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    setup do
      @trainer = create(:trainer)
      @admin = create(:admin)
      @product = create(:product)
      @application = create(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: @trainer)
    end

    teardown do
      RoleCapability.where(user_id: [@trainer, @replacement, @admin].compact.map(&:id)).delete_all
      cleanup_duplicate_review_test_data!(@application&.user, @trainer, @replacement, @admin)
      @product&.destroy!
    end

    test 'a competing no-show waits for completion and cannot replace the committed report' do
      session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
      travel_to 2.days.from_now do
        race_commands!(
          -> { CompleteService.new(TrainingSession.find(session.id), User.find(@trainer.id), completion_params).call },
          -> { NoShowService.new(TrainingSession.find(session.id), User.find(@trainer.id), no_show_notes: 'Stale absence').call }
        )
      end

      assert @holder_result.success?, @holder_result.message
      assert_not @contender_result.success?
      assert session.reload.status_completed?
      assert_equal 1, Event.where(action: 'training_completed', auditable: session).count
      assert_equal 0, Event.where(action: 'training_no_show', auditable: session).count
    end

    test 'duplicate next-appointment submissions create one appointment and one audit' do
      source = create(:training_session, :completed, application: @application, trainer: @trainer)
      params = { scheduled_for: 2.days.from_now, internal_notes: 'Preparation' }
      command = -> { ScheduleAdditionalService.new(TrainingSession.find(source.id), User.find(@trainer.id), params).call }

      race_commands!(command, command)

      assert @holder_result.success?, @holder_result.message
      assert_not @contender_result.success?
      assert_equal 1, @application.training_sessions.assigned_or_scheduled.count
      assert_equal 1, Event.where(action: 'training_scheduled', auditable: @application.training_sessions).count
    end

    test 'removal and reassignment commit before the former trainer can create from an old report' do
      source = create(:training_session, :completed, application: @application, trainer: @trainer)
      @replacement = create(:trainer)
      removal = lambda do
        application = Application.find(@application.id)
        removed = application.unassign_trainer!(actor: User.find(@admin.id))
        assigned = application.assign_trainer!(User.find(@replacement.id), actor: User.find(@admin.id))
        raise 'Coverage transfer failed' unless removed && assigned

        BaseService::Result.new(success: true)
      end
      next_session = lambda do
        ScheduleAdditionalService.new(TrainingSession.find(source.id), User.find(@trainer.id), scheduled_for: 2.days.from_now).call
      end

      race_commands!(removal, next_session)

      assert @holder_result.success?
      assert_not @contender_result.success?
      assert_equal @replacement.id, @application.reload.assigned_trainer_id
      assert_equal [@replacement.id], @application.training_sessions.assigned_or_scheduled.pluck(:trainer_id)
      assert source.reload.status_completed?
    end

    private

    def completion_params
      { product_trained_on_id: @product.id, duration_hours: 1, completed_at: 1.hour.ago,
        constituent_summary: 'We practised device controls.', summary_locale: 'en' }
    end

    def race_commands!(first_command, second_command)
      holder_ready = Queue.new
      release_holder = Queue.new
      holder_pid_queue = Queue.new
      contender_pid_queue = Queue.new
      holder = on_own_connection do
        holder_pid_queue << backend_pid
        ApplicationRecord.transaction do
          @holder_result = first_command.call
          holder_ready << true
          wait_for_signal(release_holder)
        end
      end
      holder_pid = wait_for_signal(holder_pid_queue, thread: holder)
      wait_for_signal(holder_ready, thread: holder)
      contender = on_own_connection do
        contender_pid_queue << backend_pid
        @contender_result = second_command.call
      end
      confirm_blocked_then_release(
        wait_for_signal(contender_pid_queue, thread: contender), holder_pid: holder_pid,
                                                                 release_queue: release_holder, holder_thread: holder, contender_thread: contender
      )
    ensure
      release_holder << true if release_holder
      [holder, contender].compact.each { |thread| reap_thread(thread, timeout: 10, suppress_errors: !$ERROR_INFO.nil?) }
    end
  end
end
