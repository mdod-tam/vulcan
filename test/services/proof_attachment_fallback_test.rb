# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentFallbackTest < ActiveSupport::TestCase
  self.use_transactional_tests = true

  setup do
    @application = create(:application)
    @admin = create(:admin)
    # Event.last in each test must be the event that test records.
    Event.where(action: 'proof_attachment_failed').delete_all
  end

  test 'record_failure logs event with missing submission_method gracefully' do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with("[TEST_ATTACHMENT] Proof attachment error for application #{@application.id}: StandardError").once

    proof_type = "income_#{Time.now.to_i}"

    error = StandardError.new('Test error')
    metadata = { ip_address: '127.0.0.1' }

    context = {
      application: @application,
      proof_type: proof_type,
      admin: @admin,
      submission_method: nil, # Deliberately nil submission_method
      metadata: metadata
    }

    assert_nothing_raised do
      ProofAttachmentService.record_failure(error, context)
    end

    event = Event.last
    assert_equal "#{proof_type}_proof_attachment_failed", event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_not event.metadata.key?('error_message')
    assert_not event.metadata.key?('error_backtrace')
    assert_equal 'StandardError', event.metadata['error_class']
    assert_equal 'unknown', event.metadata['submission_method'] # Default fallback
  end

  test 'record_failure logs event with invalid submission_method gracefully' do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with("[TEST_ATTACHMENT] Proof attachment error for application #{@application.id}: StandardError").once

    proof_type = "residency_#{Time.now.to_i}"

    error = StandardError.new('Test error')
    metadata = { ip_address: '127.0.0.1' }

    context = {
      application: @application,
      proof_type: proof_type,
      admin: @admin,
      submission_method: :invalid_method,
      metadata: metadata
    }

    assert_nothing_raised do
      ProofAttachmentService.record_failure(error, context)
    end

    event = Event.last
    assert_equal "#{proof_type}_proof_attachment_failed", event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_not event.metadata.key?('error_message')
    assert_not event.metadata.key?('error_backtrace')
    assert_equal 'StandardError', event.metadata['error_class']
    assert_equal 'invalid_method', event.metadata['submission_method'] # Should use the provided invalid method
  end
end
