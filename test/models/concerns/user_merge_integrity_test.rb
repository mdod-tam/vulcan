# frozen_string_literal: true

require 'test_helper'

class UserMergeIntegrityTest < ActiveSupport::TestCase
  test 'lock_for_merge_integrity! locks and returns users keyed by id, deduplicating repeats' do
    admin = create(:admin)
    constituent = create(:constituent)

    ActiveRecord::Base.transaction do
      locked = User.lock_for_merge_integrity!(admin.id, constituent, admin.id)
      assert_equal [admin.id, constituent.id].sort, locked.keys.sort
      assert_instance_of Users::Administrator, locked.fetch(admin.id)
      assert_instance_of Users::Constituent, locked.fetch(constituent.id)
    end
  end

  test 'update rejects mutation of an already-merged user even from a stale pre-merge instance' do
    canonical = create(:constituent)
    duplicate = create(:constituent)
    stale = User.find(duplicate.id) # loaded before retirement, never reloaded afterward

    duplicate.update!(merged_into_user: canonical, merged_at: Time.current, status: :inactive)

    assert_not stale.update(first_name: 'Changed')
    assert_includes stale.errors[:base], 'A merged record cannot be modified'
    assert_equal duplicate.first_name, stale.reload.first_name
  end

  test 'destroy rejects deletion of an already-merged user even from a stale pre-merge instance' do
    canonical = create(:constituent)
    duplicate = create(:constituent)
    stale = User.find(duplicate.id)

    duplicate.update!(merged_into_user: canonical, merged_at: Time.current, status: :inactive)

    assert_not stale.destroy
    assert User.exists?(duplicate.id), 'the merged record must survive a destroy attempt from a stale instance'
  end

  test 'a duplicate transitioning into the merged state for the first time is not blocked' do
    canonical = create(:constituent)
    duplicate = create(:constituent)

    assert duplicate.update(merged_into_user: canonical, merged_at: Time.current, status: :inactive)
  end

  # `.unscoped` only removes default_scopes; querying through an STI subclass still adds its
  # own `WHERE type = ...` predicate to the relation. A guard that queries `self.class.unscoped`
  # instead of the base `User.unscoped` would silently miss the live row -- and report "not
  # merged" -- for a stale instance held from before its STI type changed (e.g. an admin role
  # conversion), independent of and unrelated to the merge itself.
  test 'update rejects mutation of an already-merged user even after its STI type changed underneath a stale instance' do
    canonical = create(:constituent)
    duplicate = create(:constituent)
    stale = User.find(duplicate.id) # loaded as Users::Constituent, before the type change

    User.unscoped.where(id: duplicate.id).update_all(type: 'Users::Administrator')
    User.find(duplicate.id).update!(merged_into_user: canonical, merged_at: Time.current, status: :inactive)

    assert_instance_of Users::Constituent, stale, 'the stale instance keeps its original in-memory STI class'
    assert_not stale.update(first_name: 'Changed')
    assert_includes stale.errors[:base], 'A merged record cannot be modified'
  end
end
