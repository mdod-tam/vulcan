# frozen_string_literal: true

# Tests for ApplicationMailbox routing in unit test context
#
# This test suite verifies that emails are correctly routed to the appropriate mailboxes
# based on their recipient addresses.

require 'test_helper'
require 'action_mailbox/test_helper'

class ApplicationMailboxRoutingTest < ActionMailbox::TestCase
  include ActionMailboxTestHelper

  setup do
    # Create users needed for mailbox processing
    @constituent = create(:constituent, email: 'constituent@example.com')
    @medical_provider = create(:medical_provider, email: 'doctor@example.com')

    # Create an active application for the constituent to avoid bounce
    @application = create(:application, user: @constituent, status: :in_progress)
    @application.update_columns(
      income_proof_status: :not_reviewed,
      residency_proof_status: :not_reviewed
    )

    # Disable validation and processing to isolate routing tests - prevent before_processing callbacks
    ProofSubmissionMailbox.any_instance.stubs(:ensure_constituent_can_submit).returns(true)
    ProofSubmissionMailbox.any_instance.stubs(:validate_attachments).returns(true)
    ProofSubmissionMailbox.any_instance.stubs(:bounce_with_notification).returns(nil)
    ProofSubmissionMailbox.any_instance.stubs(:process).returns(true)
    ProofSubmissionMailbox.any_instance.stubs(:attach_proof).returns(true)

    # Medical certification mailbox stubs - prevent before_processing callbacks
    MedicalCertificationMailbox.any_instance.stubs(:ensure_medical_provider).returns(true)
    MedicalCertificationMailbox.any_instance.stubs(:ensure_valid_certification_request).returns(true)
    MedicalCertificationMailbox.any_instance.stubs(:validate_attachments).returns(true)
    MedicalCertificationMailbox.any_instance.stubs(:bounce_with_notification).returns(nil)
    MedicalCertificationMailbox.any_instance.stubs(:process).returns(true)
    MedicalCertificationMailbox.any_instance.stubs(:constituent).returns(@constituent)

    # DefaultMailbox stubs (in case the router tries to process it)
    DefaultMailbox.any_instance.stubs(:process).returns(true)

    # Stub event creation
    Event.stubs(:create!).returns(true)

    # Add rate limit and policy stubs
    RateLimit.stubs(:check!).returns(true)
    Policy.stubs(:get).returns(100) # Return a reasonable value for any policy call
  end

  test 'routes proof@mdmat.org emails to proof submission mailbox' do
    assert_mailbox_routed ProofSubmissionMailbox,
                          to: 'proof@mdmat.org',
                          from: @constituent.email,
                          subject: 'Test Subject',
                          body: 'Test Body'
  end

  test 'routes emails to Postmark inbound address to proof submission mailbox' do
    # Save original values
    original_address = MatVulcan::InboundEmailConfig.inbound_email_address

    # Set test address
    MatVulcan::InboundEmailConfig.inbound_email_address = 'test-hash@inbound.postmarkapp.com'

    assert_mailbox_routed ProofSubmissionMailbox,
                          to: 'test-hash@inbound.postmarkapp.com',
                          from: @constituent.email,
                          subject: 'Test Subject',
                          body: 'Test Body'

    # Restore original address
    MatVulcan::InboundEmailConfig.inbound_email_address = original_address
  end

  test 'routes disability_cert@mdmat.org emails to medical certification mailbox' do
    assert_mailbox_routed MedicalCertificationMailbox,
                          to: 'disability_cert@mdmat.org',
                          from: @medical_provider.email,
                          subject: 'Medical Certification',
                          body: 'Test Medical Certification'
  end

  test 'routes unmatched emails to default mailbox' do
    assert_mailbox_routed DefaultMailbox,
                          to: 'unknown@example.com',
                          from: 'sender@example.com',
                          subject: 'Unknown Email',
                          body: 'This email should go to the default mailbox'
  end
end
