# frozen_string_literal: true

require 'test_helper'

# One rule says whether a record is in standing: not merged, and neither suspended nor inactive.
# Legacy NULL status predates the enum and stays in standing. The SQL scope and every predicate built on the rule
# must agree on each standing, including the NULL one a plain NOT IN would drop.
class UserStandingTest < ActiveSupport::TestCase
  test 'the standing rule keeps active and legacy NULL status, and drops merged, suspended and inactive records' do
    users = users_by_standing

    assert_equal %i[active legacy_null_status], standings_in(users, User.in_standing.where(id: users.values.map(&:id)).ids)
  end

  test 'sign-in and delivery gates follow the standing rule' do
    users = users_by_standing.merge(admin: create(:admin))

    users.each do |standing, user|
      in_standing = %i[active legacy_null_status admin].include?(standing)

      assert_equal in_standing, user.public_login_active?, "public_login_active? for #{standing}"
      assert_equal in_standing && user.constituent?, user.secure_request_delivery_eligible?,
                   "secure_request_delivery_eligible? for #{standing}"
    end
  end

  test 'paper guardian candidates are the constituents in standing, as a predicate and as a scope' do
    users = users_by_standing.merge(admin: create(:admin))
    selected = User.paper_guardian_candidates.where(id: users.values.map(&:id)).ids

    assert_equal %i[active legacy_null_status], standings_in(users, selected)
    users.each do |standing, user|
      assert_equal selected.include?(user.id), user.paper_guardian_candidate?, "paper_guardian_candidate? for #{standing}"
    end
  end

  test 'vendors for equipment procurement are the vendors in standing' do
    survivor = create(:vendor)
    null_status = create(:vendor)
    null_status.update_column(:status, nil)
    vendors = {
      active: survivor,
      legacy_null_status: null_status,
      inactive: create(:vendor, status: :inactive),
      suspended: create(:vendor, status: :suspended),
      merged: create(:vendor, status: :active, merged_into_user: survivor)
    }

    selected = Users::Vendor.equipment_procurement_eligible.where(id: vendors.values.map(&:id)).ids

    assert_equal %i[active legacy_null_status], standings_in(vendors, selected)
  end

  test 'staff pickers exclude merged, suspended and inactive evaluators and keep the legacy NULL status' do
    survivor = create(:evaluator)
    null_status = create(:evaluator)
    null_status.update_column(:status, nil)
    evaluators = {
      active: survivor,
      legacy_null_status: null_status,
      inactive: create(:evaluator, status: :inactive),
      suspended: create(:evaluator, status: :suspended),
      merged: create(:evaluator, status: :active, merged_into_user: survivor)
    }

    selected = User.assignable_for(:can_evaluate).where(id: evaluators.values.map(&:id)).ids

    assert_equal %i[active legacy_null_status], standings_in(evaluators, selected)
  end

  private

  # One constituent per standing the rule tells apart.
  def users_by_standing
    survivor = create(:constituent)
    legacy_null_status = create(:constituent)
    legacy_null_status.update_column(:status, nil)

    {
      active: survivor,
      legacy_null_status: legacy_null_status,
      inactive: create(:constituent, status: :inactive),
      suspended: create(:constituent, status: :suspended),
      merged: create(:constituent, status: :active, merged_into_user: survivor),
      merged_and_suspended: create(:constituent, status: :suspended, merged_into_user: survivor)
    }
  end

  def standings_in(users, selected_ids)
    users.select { |_standing, user| selected_ids.include?(user.id) }.keys.sort
  end
end
