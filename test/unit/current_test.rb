# frozen_string_literal: true

require 'test_helper'

class CurrentTest < ActiveSupport::TestCase
  def setup
    Current.reset
  end

  def teardown
    Current.reset
  end

  test 'paper_context can be set and retrieved' do
    assert_nil Current.paper_context
    assert_not Current.paper_context?

    Current.paper_context = true
    assert Current.paper_context
    assert Current.paper_context?

    Current.paper_context = false
    assert_not Current.paper_context
    assert_not Current.paper_context?
  end

  test 'skip_proof_validation can be set and retrieved' do
    assert_nil Current.skip_proof_validation
    assert_not Current.skip_proof_validation?

    Current.skip_proof_validation = true
    assert Current.skip_proof_validation
    assert Current.skip_proof_validation?

    Current.skip_proof_validation = false
    assert_not Current.skip_proof_validation
    assert_not Current.skip_proof_validation?
  end

  test 'reviewing_single_proof can be set and retrieved' do
    assert_nil Current.reviewing_single_proof
    assert_not Current.reviewing_single_proof?

    Current.reviewing_single_proof = true
    assert Current.reviewing_single_proof
    assert Current.reviewing_single_proof?

    Current.reviewing_single_proof = false
    assert_not Current.reviewing_single_proof
    assert_not Current.reviewing_single_proof?
  end

  test 'force_notifications can be set and retrieved' do
    assert_nil Current.force_notifications
    assert_not Current.force_notifications?

    Current.force_notifications = true
    assert Current.force_notifications
    assert Current.force_notifications?

    Current.force_notifications = false
    assert_not Current.force_notifications
    assert_not Current.force_notifications?
  end

  test 'test_user_id can be set and retrieved' do
    assert_nil Current.test_user_id

    Current.test_user_id = 123
    assert_equal 123, Current.test_user_id

    Current.test_user_id = nil
    assert_nil Current.test_user_id
  end

  test 'multiple attributes can be set independently' do
    Current.paper_context = true
    Current.skip_proof_validation = true
    Current.test_user_id = 456

    assert Current.paper_context?
    assert Current.skip_proof_validation?
    assert_equal 456, Current.test_user_id
  end

  test 'reset clears all attributes' do
    Current.paper_context = true
    Current.skip_proof_validation = true
    Current.test_user_id = 789

    Current.reset

    assert_nil Current.paper_context
    assert_nil Current.skip_proof_validation
    assert_nil Current.test_user_id
    assert_not Current.paper_context?
    assert_not Current.skip_proof_validation?
  end

  test 'set scopes nil, false, and true values to its block and restores each one' do
    [nil, false, true].each do |outer|
      Current.paper_context = outer
      Current.set(paper_context: true) do
        assert Current.paper_context?
        Current.set(paper_context: false) { assert_not Current.paper_context? }
        assert Current.paper_context?
      end
      assert_equal outer, Current.paper_context
    end
  end

  test 'set restores on an early return or exception and leaves unrelated attributes alone' do
    actor = Object.new
    Current.user = actor
    Current.ip_address = '203.0.113.9'

    early_return = lambda do
      Current.set(paper_context: true) { return :early }
    end
    assert_equal :early, early_return.call
    assert_nil Current.paper_context

    assert_raises(RuntimeError) { Current.set(reviewing_single_proof: true) { raise 'boom' } }
    assert_nil Current.reviewing_single_proof

    Current.set(paper_context: true, reviewing_single_proof: true) { assert_same actor, Current.user }
    assert_same actor, Current.user
    assert_equal '203.0.113.9', Current.ip_address
  end

  test 'set returns the value of its block' do
    assert_equal :result, Current.set(paper_context: true) { :result }
  end

  test 'attributes are isolated between test runs' do
    assert_nil Current.paper_context
    assert_nil Current.skip_proof_validation
    assert_nil Current.test_user_id
  end
end
