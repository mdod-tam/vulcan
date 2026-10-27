# frozen_string_literal: true

require 'test_helper'

module Users
  # Assignment and access removal serialize on the practitioner's user row, in either order.
  class CapabilityWriterConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    include ConcurrencyTestHelper

    Intent = CapabilityWriter::Intent

    setup do
      Policy.find_or_create_by!(key: 'waiting_period_years') { |policy| policy.value = 3 }
      Policy.find_or_create_by!(key: 'max_training_sessions') { |policy| policy.value = 3 }
      @admin = create(:admin)
      @practitioner = create(:evaluator)
      create(:role_capability, user: @practitioner, capability: 'can_train')
      @application = create(:application, :approved, :with_all_proofs, application_date: Date.current)
    end

    teardown do
      RoleCapability.where(user_id: @practitioner.id).delete_all
      TrainingSession.where(application_id: @application.id).delete_all
      cleanup_duplicate_review_test_data!(@application&.user, @practitioner, @admin)
    end

    test 'assignment commits first: removal then sees the new work and asks for a fresh confirmation' do
      race_commands!(
        -> { Application.find(@application.id).assign_trainer!(User.find(@practitioner.id), actor: User.find(@admin.id)) },
        -> { revoke_training }
      )

      assert_equal true, @holder_result
      assert_equal :confirmation_required, @contender_result.status
      assert_equal 1, @contender_result.impact.sole.open_count
      assert User.find(@practitioner.id).explicit_grant?('can_train')
      assert_equal @practitioner.id, @application.reload.assigned_trainer_id
    end

    test 'removal commits first: assignment then waits, re-reads eligibility, and refuses' do
      race_commands!(
        -> { revoke_training },
        -> { Application.find(@application.id).tap { |application| @refusal = application }.assign_trainer!(User.find(@practitioner.id), actor: User.find(@admin.id)) }
      )

      assert @holder_result.changed?, @holder_result.message
      assert_equal false, @contender_result
      assert_includes @refusal.errors[:base], 'Select an active trainer.'
      assert_not User.find(@practitioner.id).assignable_trainer?
      assert_empty TrainingSession.where(application_id: @application.id)
    end

    test 'two identical requests write one receipt and one set of effects' do
      operation_id = SecureRandom.uuid
      race_commands!(
        -> { revoke_training(operation_id: operation_id) },
        -> { revoke_training(operation_id: operation_id) }
      )

      assert_equal :changed, @holder_result.status
      assert_equal :already_applied, @contender_result.status
      assert_equal 1, Event.where(action: CapabilityWriter::RECEIPT_ACTION, auditable: User.find(@practitioner.id)).count
      assert_equal 1, Event.where(action: 'capability_removed', auditable: User.find(@practitioner.id)).count
    end

    private

    def revoke_training(operation_id: SecureRandom.uuid)
      CapabilityWriter.call(actor: User.find(@admin.id), user: User.find(@practitioner.id), intent: Intent.revoke('can_train'),
                            operation_id: operation_id)
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
