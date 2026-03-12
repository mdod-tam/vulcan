# frozen_string_literal: true

require 'test_helper'

class ApplicationMailboxTest < ActionMailbox::TestCase
  test 'routes emails to Postmark inbound address to ProofSubmissionMailbox' do
    # Create mock inbound email that will be routed but not processed
    inbound_email = create_inbound_email_from_source(
      Mail.new(
        to: MatVulcan::InboundEmailConfig.inbound_email_address,
        from: 'test@example.com',
        subject: 'Proof submission',
        body: 'Test email body'
      ).to_s
    )

    # Check that the routing resolves to the correct mailbox class
    mailbox_class = ApplicationMailbox.mailbox_for(inbound_email)
    assert_equal ProofSubmissionMailbox, mailbox_class
  end

  test 'routes proof@mdmat.org emails to ProofSubmissionMailbox' do
    inbound_email = create_inbound_email_from_source(
      Mail.new(
        to: 'proof@mdmat.org',
        from: 'test@example.com',
        subject: 'Proof submission',
        body: 'Test email body'
      ).to_s
    )

    mailbox_class = ApplicationMailbox.mailbox_for(inbound_email)
    assert_equal ProofSubmissionMailbox, mailbox_class
  end

  test 'routes disability_cert@mdmat.org emails to MedicalCertificationMailbox' do
    inbound_email = create_inbound_email_from_source(
      Mail.new(
        to: 'disability_cert@mdmat.org',
        from: 'doctor@example.com',
        subject: 'Medical certification',
        body: 'Medical certification document'
      ).to_s
    )

    mailbox_class = ApplicationMailbox.mailbox_for(inbound_email)
    assert_equal MedicalCertificationMailbox, mailbox_class
  end

  test 'routes unmatched emails to DefaultMailbox' do
    inbound_email = create_inbound_email_from_source(
      Mail.new(
        to: 'unknown@example.com',
        from: 'test@example.com',
        subject: 'Unknown email',
        body: 'Unknown email body'
      ).to_s
    )

    mailbox_class = ApplicationMailbox.mailbox_for(inbound_email)
    assert_equal DefaultMailbox, mailbox_class
  end

  private

  # Helper to create an InboundEmail without processing it
  def create_inbound_email_from_source(source)
    ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
  end
end
