# frozen_string_literal: true

require 'test_helper'

class CurrentTest < ActiveSupport::TestCase
  def setup
    # Ensure clean state before each test
    Current.reset
  end

  def teardown
    # Ensure clean state after each test
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

  test 'attributes are isolated between test runs' do
    # This test verifies that Current attributes don't leak between tests
    # The setup/teardown should ensure this, but let's verify
    assert_nil Current.paper_context
    assert_nil Current.skip_proof_validation
    assert_nil Current.test_user_id
  end
end
