# frozen_string_literal: true

require 'test_helper'

class UserCapabilitiesTest < ActiveSupport::TestCase
  MATRIX = {
    admin: [%w[can_train can_evaluate], []],
    evaluator: [%w[can_evaluate], %w[can_train]],
    trainer: [%w[can_train], %w[can_evaluate]],
    constituent: [[], []],
    vendor: [[], []]
  }.freeze

  test 'the policy matrix decides what each role provides and may be granted' do
    MATRIX.each do |role, (provided, grantable)|
      user = create(role)
      assert_equal provided, user.role_provided_capabilities, "#{role} provides"
      assert_equal grantable, user.grantable_capabilities, "#{role} grantable"
    end
    assert_predicate UserRolesAndCapabilities::CAPABILITY_MATRIX, :frozen?
    assert(UserRolesAndCapabilities::CAPABILITY_MATRIX.values.all? { |policy| policy.frozen? && policy.values.all?(&:frozen?) })
  end

  test 'a grant makes the other discipline effective only where the matrix allows it' do
    evaluator = create(:evaluator)
    assert_not evaluator.can_train?

    create(:role_capability, user: evaluator, capability: 'can_train')

    assert evaluator.reload.can_train?
    assert evaluator.can_evaluate?
    assert_equal %w[can_train can_evaluate].sort, evaluator.effective_capabilities.sort
  end

  test 'a stored row the matrix forbids confers nothing and never makes anyone eligible' do
    constituent = create(:constituent)
    redundant_trainer = create(:trainer)
    [constituent, redundant_trainer].zip(%w[can_train can_train]).each do |user, capability|
      RoleCapability.new(user: user, capability: capability).save!(validate: false)
    end

    assert_not constituent.reload.can_train?
    assert_not User.assignable_for(:can_train).exists?(constituent.id)
    assert_equal %w[can_train], redundant_trainer.reload.effective_capabilities
    assert_not redundant_trainer.explicit_grant?('can_train')
  end

  test 'role capabilities refuse grants the role does not allow' do
    {
      create(:constituent) => 'can_train', create(:vendor) => 'can_evaluate', create(:admin) => 'can_train',
      create(:trainer) => 'can_train', create(:evaluator) => 'can_evaluate'
    }.each do |user, capability|
      grant = RoleCapability.new(user: user, capability: capability)
      assert_not grant.valid?, "#{user.type} #{capability}"
      assert_includes grant.errors[:capability].to_sentence, 'cannot be granted'
    end
    assert_not RoleCapability.new(user: create(:evaluator), capability: 'can_fly').valid?
  end

  test 'the eligibility relation and the predicates agree for every role, status, and merge state' do
    staff = %i[admin evaluator trainer].flat_map do |role|
      [create(role), create(role, status: :inactive), create(role, status: :suspended), create(role).tap { |user| user.update_column(:status, nil) }]
    end
    granted_evaluator = create(:evaluator)
    create(:role_capability, user: granted_evaluator, capability: 'can_train')
    granted_trainer = create(:trainer)
    create(:role_capability, user: granted_trainer, capability: 'can_evaluate')
    merged = create(:evaluator).tap { |user| user.update_column(:merged_into_user_id, create(:evaluator).id) }
    users = staff + [granted_evaluator, granted_trainer, merged, create(:constituent), create(:vendor)]

    { can_train: :assignable_trainer?, can_evaluate: :assignable_evaluator? }.each do |capability, predicate|
      relation = User.assignable_for(capability).where(id: users.map(&:id))
      users.each do |user|
        assert_equal user.reload.public_send(predicate), relation.include?(user), "#{user.type} #{user.status.inspect} #{predicate}"
      end
    end
    assert_predicate users.find { |user| user.status.nil? && user.admin? }.reload, :assignable_trainer?
    assert_not merged.reload.assignable_evaluator?
  end

  test 'an unsaved user is never assignable' do
    assert_not build(:evaluator).assignable_evaluator?
    assert_not build(:trainer).assignable_trainer?
  end

  test 'grants read the same loaded or unloaded, and a loaded page makes no query per row' do
    users = create_list(:evaluator, 3).each { |user| create(:role_capability, user: user, capability: 'can_train') }
    plain = users.map { |user| User.find(user.id).effective_capabilities }
    loaded = User.preload(:role_capabilities).where(id: users.map(&:id)).order(:id).to_a

    assert_equal plain, loaded.map(&:effective_capabilities)
    assert_no_queries { loaded.each { |user| [user.can_train?, user.can_evaluate?, user.explicit_grant?('can_train'), user.assignable_trainer?] } }
  end

  test 'assigned work is reachable by discipline for any user who holds it' do
    trainer_with_evaluation_grant = create(:trainer)
    create(:role_capability, user: trainer_with_evaluation_grant, capability: 'can_evaluate')
    evaluation = create(:evaluation, evaluator: trainer_with_evaluation_grant)
    session = create(:training_session, trainer: trainer_with_evaluation_grant)

    assert_equal [evaluation], trainer_with_evaluation_grant.assigned_evaluations.to_a
    assert_equal [session], trainer_with_evaluation_grant.assigned_training_sessions.to_a
    assert_equal [evaluation.constituent], trainer_with_evaluation_grant.assigned_evaluation_constituents.to_a
    assert_not trainer_with_evaluation_grant.destroy
    assert_predicate trainer_with_evaluation_grant.errors, :any?
  end
end
