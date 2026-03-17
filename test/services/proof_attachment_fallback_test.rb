# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentFallbackTest < ActiveSupport::TestCase
  # Since both tests modify the database similarly, run them one at a time
  self.use_transactional_tests = true

  setup do
    @application = create(:application) # Use basic FactoryBot application factory
    @admin = create(:admin)
    # Clear out any existing audit records to ensure our tests are isolated
    Event.where(action: 'proof_attachment_failed').delete_all
  end

  test 'record_failure logs event with missing submission_method gracefully' do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/\[TEST_ATTACHMENT\] Proof attachment error: Test error/)).once

    # Generate a test-specific proof type to avoid conflicts
    proof_type = "income_#{Time.now.to_i}"

    # Deliberately passing nil as submission_method to test fallback
    error = StandardError.new('Test error')
    metadata = { ip_address: '127.0.0.1' }

    # Build context hash as expected by the current method signature
    context = {
      application: @application,
      proof_type: proof_type,
      admin: @admin,
      submission_method: nil, # Deliberately nil submission_method
      metadata: metadata
    }

    # This should not raise an error due to our fallback handling
    assert_nothing_raised do
      ProofAttachmentService.record_failure(error, context)
    end

    # Verify audit event was created with fallback submission method
    event = Event.last
    assert_equal "#{proof_type}_proof_attachment_failed", event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_equal 'Test error', event.metadata['error_message']
    assert_equal 'StandardError', event.metadata['error_class']
    assert_equal 'unknown', event.metadata['submission_method'] # Default fallback
  end

  test 'record_failure logs event with invalid submission_method gracefully' do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/\[TEST_ATTACHMENT\] Proof attachment error: Test error/)).once

    # Generate a test-specific proof type to avoid conflicts
    proof_type = "residency_#{Time.now.to_i}"

    # Deliberately passing an invalid submission_method to test fallback
    error = StandardError.new('Test error')
    metadata = { ip_address: '127.0.0.1' }

    # Build context hash as expected by the current method signature
    context = {
      application: @application,
      proof_type: proof_type,
      admin: @admin,
      submission_method: :invalid_method, # Invalid submission method
      metadata: metadata
    }

    # This should not raise an error due to our fallback handling
    assert_nothing_raised do
      ProofAttachmentService.record_failure(error, context)
    end

    # Verify audit event was created with fallback submission method
    event = Event.last
    assert_equal "#{proof_type}_proof_attachment_failed", event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_equal 'Test error', event.metadata['error_message']
    assert_equal 'StandardError', event.metadata['error_class']
    assert_equal 'invalid_method', event.metadata['submission_method'] # Should use the provided invalid method
  end
end
