# frozen_string_literal: true

require 'test_helper'

module Baseline
  class PoliciesTest < ActiveSupport::TestCase
    setup do
      @actor = create(:admin)
    end

    test 'reset restores edited values through the model with a policy change record' do
      edit_policy('max_proof_rejections', 9)

      assert_difference 'PolicyChange.count', 1 do
        Policies.reset!(actor: @actor)
      end

      assert_equal 3, Policy.get('max_proof_rejections')
      change = PolicyChange.order(:id).last
      assert_equal [@actor.id, 9, 3], [change.user_id, change.previous_value, change.new_value]
    end

    test 'reset creates a missing policy and is repeatable in one process' do
      Policy.find_by!(key: 'waiting_period_years').destroy!

      assert_difference 'Policy.count', 1 do
        Policies.reset!(actor: @actor)
      end
      edit_policy('waiting_period_years', 7)

      assert_no_difference 'Policy.count' do
        Policies.reset!(actor: @actor)
      end
      assert_equal Policies::DEFAULTS, Policy.where(key: Policies::DEFAULTS.keys).pluck(:key, :value).to_h
    end

    test 'reset without an actor cannot silently change an existing value' do
      edit_policy('max_proof_rejections', 9)

      assert_raises(ActiveRecord::RecordInvalid) { Policies.reset!(actor: nil) }
      assert_equal 9, Policy.get('max_proof_rejections')
    end

    private

    def edit_policy(key, value)
      policy = Policy.find_by!(key: key)
      policy.updated_by = @actor
      policy.update!(value: value)
    end
  end
end
