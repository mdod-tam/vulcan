# frozen_string_literal: true

require 'test_helper'

module Users
  class CapabilityWriterTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    Intent = CapabilityWriter::Intent

    setup do
      @admin = create(:admin)
      @evaluator = create(:evaluator)
      @trainer = create(:trainer)
    end

    test 'granting an allowed capability stores it, makes the user eligible, and records audit and receipt together' do
      result = write(@evaluator, Intent.grant('can_train'))

      assert result.changed?
      assert @evaluator.reload.assignable_trainer?
      assert_includes User.assignable_for(:can_train), @evaluator
      event = Event.find_by!(action: 'capability_granted', auditable: @evaluator)
      assert_equal [@admin.id, 'can_train', 'explicit_grant', ['can_evaluate'], %w[can_evaluate can_train]],
                   event.metadata.values_at('acting_admin_id', 'capability', 'source', 'before_access', 'after_access')
      assert_equal 'changed', receipt_for(@evaluator).metadata['outcome']
    end

    test 'every grant the matrix forbids is refused without a row, event, or receipt' do
      refused = {
        'a constituent' => [create(:constituent), 'can_train'],
        'a vendor' => [create(:vendor), 'can_evaluate'],
        'an administrator' => [@admin, 'can_train'],
        'a trainer for its own capability' => [@trainer, 'can_train'],
        'an unknown capability' => [@evaluator, 'can_fly']
      }

      refused.each do |name, (user, capability)|
        assert_no_difference ['RoleCapability.count', 'Event.count'] do
          result = write(user, Intent.grant(capability))
          assert_equal :refused, result.status, name
          assert_predicate result.message, :present?
        end
      end
    end

    test 'a duplicate grant is an accepted no-op that writes only a receipt' do
      write(@evaluator, Intent.grant('can_train'))

      assert_no_difference ['RoleCapability.count', "Event.where(action: 'capability_granted').count"] do
        result = write(@evaluator, Intent.grant('can_train'))
        assert_equal :unchanged, result.status
      end
      assert_equal 'unchanged', Event.where(action: described_receipt, auditable: @evaluator).order(:id).last.metadata['outcome']
    end

    test 'revoking an explicit grant with no open work removes it and records the loss' do
      create(:role_capability, user: @evaluator, capability: 'can_train')

      result = write(@evaluator, Intent.revoke('can_train'))

      assert result.changed?
      assert_not @evaluator.reload.assignable_trainer?
      assert_equal 'explicit_grant', Event.find_by!(action: 'capability_removed', auditable: @evaluator).metadata['source']
    end

    test 'revoking role-provided access is refused and an absent grant is a no-op' do
      assert_equal :refused, write(@trainer, Intent.revoke('can_train')).status
      assert_equal :unchanged, write(@trainer, Intent.revoke('can_evaluate')).status
    end

    test 'removing training with open work asks for confirmation, writes nothing, and counts the affected assignments' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      sessions = create_open_training_sessions(@evaluator, 2)

      assert_no_difference ['RoleCapability.count', 'Event.count'] do
        result = write(@evaluator, Intent.revoke('can_train'))

        assert_equal :confirmation_required, result.status
        assert_equal [2, 2], [result.impact.sole.open_count, result.impact.sole.application_ids.size]
        assert_predicate result.token, :present?
      end
      assert(sessions.all? { |session| session.reload.trainer_id == @evaluator.id })
    end

    test 'a valid confirmation removes access, keeps the assignments, and audits each application' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      sessions = create_open_training_sessions(@evaluator, 2)
      operation_id = SecureRandom.uuid
      token = write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id).token

      result = write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id, confirmation: token)

      assert result.changed?
      assert_equal sessions.map(&:id).sort, TrainingSession.where(trainer_id: @evaluator.id).pluck(:id).sort
      assert_equal 2, Event.where(action: 'trainer_access_removed').count
      event = Event.where(action: 'trainer_access_removed', auditable: sessions.first.application).sole
      assert_equal [@evaluator.id, 'capability_removed', [sessions.first.id]],
                   event.metadata.values_at('former_practitioner_id', 'reason', 'training_session_ids')
      assert_includes User.where(id: @evaluator.id).pluck(:id), @evaluator.id
      assert_includes Application.needing_trainer_reassignment.pluck(:id), sessions.first.application_id
    end

    test 'a confirmation that is expired, tampered, or bound to other facts never authorizes the change' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      session = create_open_training_sessions(@evaluator, 1).sole
      operation_id = SecureRandom.uuid
      token = write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id).token
      other_admin = create(:admin)

      attempts = {
        'tampered' => -> { write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id, confirmation: "#{token}x") },
        'another operation' => -> { write(@evaluator, Intent.revoke('can_train'), operation_id: SecureRandom.uuid, confirmation: token) },
        'another actor' => -> { write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id, confirmation: token, actor: other_admin) },
        'another target' => lambda {
          other = create(:evaluator)
          create(:role_capability, user: other, capability: 'can_train')
          create_open_training_sessions(other, 1)
          write(other, Intent.revoke('can_train'), operation_id: operation_id, confirmation: token)
        },
        'another intent' => -> { write(@evaluator, Intent.change_role(Users::Vendor), operation_id: operation_id, confirmation: token) },
        'edited work with the same count' => lambda {
          session.touch
          write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id, confirmation: token)
        },
        'expired' => -> { travel(CapabilityWriter::TOKEN_TTL + 1.minute) { write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id, confirmation: token) } }
      }

      attempts.each do |name, attempt|
        result = attempt.call
        assert_includes %i[stale confirmation_required], result.status, name
        assert @evaluator.reload.explicit_grant?('can_train'), "#{name} must not remove the grant"
      end
    end

    test 'removing evaluation access names evaluations and role changes warn about each actual loss' do
      create(:role_capability, user: @trainer, capability: 'can_evaluate')
      create(:evaluation, evaluator: @trainer, status: :requested)

      evaluation_loss = write(@trainer, Intent.revoke('can_evaluate'))
      assert_equal %w[evaluation], evaluation_loss.impact.map(&:noun)

      create(:training_session, trainer: @trainer, status: :requested)
      role_loss = write(@trainer, Intent.change_role(Users::Constituent))
      assert_equal %w[can_evaluate can_train], role_loss.impact.map(&:capability).sort
    end

    test 'a role change that keeps the capability is not a loss, and it clears explicit grants' do
      create(:role_capability, user: @evaluator, capability: 'can_train')
      create(:evaluation, evaluator: @evaluator, status: :requested)

      result = write(@evaluator, Intent.change_role(Users::Administrator))

      assert result.changed?, result.message
      assert_instance_of Users::Administrator, User.find(@evaluator.id)
      assert_empty RoleCapability.where(user_id: @evaluator.id)
      assert_equal %w[can_train can_evaluate].sort, User.find(@evaluator.id).effective_capabilities.sort
    end

    test 'a role change refuses self conversion, a missing birth date, and an unchanged role truthfully' do
      assert_equal :refused, write(@admin, Intent.change_role(Users::Trainer)).status
      assert_equal :refused, write(create(:evaluator, date_of_birth: nil), Intent.change_role(Users::Constituent)).status
      assert_equal :unchanged, write(@trainer, Intent.change_role(Users::Trainer)).status
    end

    test 'an ineligible acting user is refused before anything is read or written' do
      [create(:constituent), create(:admin, status: :inactive)].each do |actor|
        assert_no_difference ['RoleCapability.count', 'Event.count'] do
          assert_equal :refused, write(@evaluator, Intent.grant('can_train'), actor: actor).status
        end
      end
    end

    test 'replaying an operation returns its first outcome and never re-evaluates current state' do
      grant_operation = SecureRandom.uuid
      write(@evaluator, Intent.grant('can_train'), operation_id: grant_operation)
      revoke_operation = SecureRandom.uuid
      write(@evaluator, Intent.revoke('can_train'), operation_id: revoke_operation)
      write(@evaluator, Intent.grant('can_train'), operation_id: SecureRandom.uuid)

      assert_equal :already_applied, write(@evaluator, Intent.revoke('can_train'), operation_id: revoke_operation).status
      assert_equal :already_applied, write(@evaluator, Intent.grant('can_train'), operation_id: grant_operation).status
      assert @evaluator.reload.explicit_grant?('can_train'), 'the replayed removal must not remove the new grant'
      assert_equal :refused, write(@evaluator, Intent.grant('can_evaluate'), operation_id: grant_operation).status
    end

    test 'an earlier no-op removal cannot become destructive after a later grant' do
      operation_id = SecureRandom.uuid
      assert_equal :unchanged, write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id).status
      write(@evaluator, Intent.grant('can_train'))

      assert_equal :already_applied, write(@evaluator, Intent.revoke('can_train'), operation_id: operation_id).status
      assert @evaluator.reload.explicit_grant?('can_train')
    end

    test 'a failed required audit rolls back the grant and its receipt' do
      AuditEventService.stubs(:log).returns(nil)

      assert_no_difference ['RoleCapability.count', 'Event.count'] do
        assert_raises(RuntimeError) { write(@evaluator, Intent.grant('can_train')) }
      end
    end

    test 'two losses in one operation stay two visible events with a shared correlation id' do
      create(:role_capability, user: @trainer, capability: 'can_evaluate')
      operation_id = SecureRandom.uuid

      write(@trainer, Intent.change_role(Users::Constituent), operation_id: operation_id)

      events = Event.where(action: 'capability_removed', auditable: @trainer)
      assert_equal %w[can_evaluate can_train], events.map { |event| event.metadata['capability'] }.sort
      assert_equal [operation_id], events.map { |event| event.metadata['correlation_id'] }.uniq
      assert_equal 1, Event.where(action: described_receipt, auditable: @trainer).count
    end

    private

    def write(user, intent, operation_id: SecureRandom.uuid, confirmation: nil, actor: @admin)
      CapabilityWriter.call(actor: actor, user: user, intent: intent, operation_id: operation_id, confirmation: confirmation)
    end

    def receipt_for(user) = Event.where(action: described_receipt, auditable: user).order(:id).last

    def described_receipt = CapabilityWriter::RECEIPT_ACTION

    def create_open_training_sessions(trainer, count)
      Array.new(count) { create(:training_session, trainer: trainer, status: :requested) }
    end
  end
end
