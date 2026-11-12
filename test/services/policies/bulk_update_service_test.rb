# frozen_string_literal: true

require 'test_helper'

module Policies
  class BulkUpdateServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @first = create(:policy, value: 10)
      @second = create(:policy, value: 20)
    end

    test 'array and keyed batches update actual values with an attributed history for each changed policy' do
      assert_difference('PolicyChange.count', 2) do
        result = BulkUpdateService.new(policies_data: [{ id: @first.id, value: 11 }, { id: @second.id, value: 21 }], current_user: @admin).call
        assert_predicate result, :success?
      end
      assert_equal [11, 21], [@first.reload.value, @second.reload.value]
      changes = [@first, @second].map { |policy| policy.policy_changes.sole }
      assert_equal([[10, 11], [20, 21]], changes.map { |change| [change.previous_value, change.new_value] })
      assert_equal [@admin.id, @admin.id], changes.map(&:user_id)

      assert_difference('PolicyChange.count', 1) do
        result = BulkUpdateService.new(policies_data: { @first.id.to_s => { id: @first.id, value: 12 } }, current_user: @admin).call
        assert_predicate result, :success?
      end
      assert_equal 12, @first.reload.value
      change = @first.policy_changes.order(:id).last
      assert_equal [11, 12, @admin.id], [change.previous_value, change.new_value, change.user_id]
    end

    test 'an invalid later value rolls back earlier values and their audit history' do
      assert_no_difference('PolicyChange.count') do
        result = BulkUpdateService.new(policies_data: [{ id: @first.id, value: 11 }, { id: @second.id, value: nil }], current_user: @admin).call
        assert_predicate result, :failure?
        assert_match 'Failed to update policies:', result.message
      end
      assert_equal [10, 20], [@first.reload.value, @second.reload.value]
    end

    test 'a missing later policy rolls back earlier values and their audit history' do
      assert_no_difference('PolicyChange.count') do
        result = BulkUpdateService.new(policies_data: [{ id: @first.id, value: 11 }, { id: Policy.maximum(:id) + 1, value: 21 }], current_user: @admin).call
        assert_predicate result, :failure?
        assert_equal 'Failed to update policies: Could not find one or more policies', result.message
      end
      assert_equal [10, 20], [@first.reload.value, @second.reload.value]
    end
  end
end
