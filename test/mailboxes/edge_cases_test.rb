# frozen_string_literal: true

require 'test_helper'
require 'support/action_mailbox_test_helper'

class EdgeCasesTest < ActionMailbox::TestCase
  include ActionMailboxTestHelper

  setup do
    # Create a constituent and application using factories with unique emails
    # to avoid potential clashes during test runs.
    constituent_email = "constituent_#{SecureRandom.hex(4)}@example.com"
    medical_provider_email = "doctor_#{SecureRandom.hex(4)}@example.com"

    @constituent = create(:constituent, email: constituent_email)
    @application = create(:application, user: @constituent, total_rejections: 0)
    # The email is now set during creation, so no separate update is needed for @constituent.

    # Create a medical provider using factory
    @medical_provider = create(:medical_provider, email: medical_provider_email)

    # Create policy records for rate limiting, using find_or_create_by to avoid uniqueness constraint errors
    %i[proof_submission_rate_limit_web proof_submission_rate_limit_email
       proof_submission_rate_period max_proof_rejections].each do |trait|
      factory_attributes = FactoryBot.attributes_for(:policy, trait)
      Policy.find_or_create_by(key: factory_attributes[:key]) do |policy|
        policy.value = factory_attributes[:value]
      end
    end

    # Set up ApplicationMailbox routing for testing
    ApplicationMailbox.instance_eval do
      routing(/proof@/i => :proof_submission)
      routing(/medical-cert@/i => :medical_certification)
      routing(/.+/ => :default)
    end

    # Stub email template finder to prevent "Email templates not found" errors
    # This allows tests to run without requiring templates to exist in test DB
    # Create a specific mock for the proof_submission_error template
    proof_submission_error_template = mock('EmailTemplate')
    proof_submission_error_template.stubs(:render).returns(['Error Processing Your Proof Submission', 'Test Email Body'])
    proof_submission_error_template.stubs(:enabled?).returns(true)

    # Create a generic mock for other templates
    generic_template = mock('EmailTemplate')
    generic_template.stubs(:render).returns(['Test Email Subject', 'Test Email Body'])
    generic_template.stubs(:enabled?).returns(true)

    # Ensure the template lookup uses the correct template based on name
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_submission_error',
                                        format: :text).returns(proof_submission_error_template)
    EmailTemplate.stubs(:find_by!).returns(generic_template) # Fallback for any other template
  end

  test 'handles emails with no attachments' do
    # We need to use assert_throws to catch the bounce
    assert_throws(:bounce) do
      inbound_email = create_inbound_email_from_mail(
        to: 'proof@example.com',
        from: @constituent.email,
        subject: 'Income Proof Submission',
        body: 'I forgot to attach my proof.'
      )

      # Process the email
      inbound_email.route
    end
  end

  test 'handles emails with unsupported attachment types' do
    # Create a temporary file for testing
    file_path = Rails.root.join('tmp/income_proof.exe')
    File.write(file_path, 'This is not a valid document')

    # We need to stub the ProofAttachmentValidator to force validation failure
    # ValidationError requires error_type and message
    ProofAttachmentValidator.expects(:validate!)
                            .raises(ProofAttachmentValidator::ValidationError.new(:invalid_type, 'Unsupported file type'))

    assert_throws(:bounce) do
      inbound_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: @constituent.email,
        subject: 'Income Proof Submission',
        body: 'Please find my income proof attached.',
        attachment_path: file_path,
        content_type: 'application/octet-stream'
      )

      # Process the email
      inbound_email.route
    end

    # Clean up
    FileUtils.rm_f(file_path)
  end

  test 'handles emails with very large attachments' do
    skip 'Large file validation not implemented' unless defined?(ProofAttachmentValidator) &&
                                                        ProofAttachmentValidator.method_defined?(:validate_file_size)

    # Create a large temporary file for testing
    file_path = Rails.root.join('tmp/large_income_proof.pdf')
    File.write(file_path, 'X' * 11.megabytes)

    # We need to stub the ProofAttachmentValidator to force validation failure due to size
    # ValidationError requires error_type and message
    ProofAttachmentValidator.expects(:validate!)
                            .raises(ProofAttachmentValidator::ValidationError.new(:file_too_large, 'File too large'))

    assert_throws(:bounce) do
      inbound_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: @constituent.email,
        subject: 'Income Proof Submission',
        body: 'Please find my income proof attached.',
        attachment_path: file_path,
        content_type: 'application/pdf'
      )

      # Process the email
      inbound_email.route
    end

    # Clean up
    FileUtils.rm_f(file_path)
  end

  test 'handles emails with ambiguous proof type' do
    # Create a temporary file for testing
    file_path = Rails.root.join('tmp/proof.pdf')
    File.write(file_path, 'This is a test PDF file')

    # We need to stub ProofAttachmentValidator to pass validation
    ProofAttachmentValidator.stubs(:validate!).returns(true)

    # Stub the attach_proof method to prevent actual attachment but still track calls
    ProofSubmissionMailbox.any_instance.expects(:attach_proof).at_least_once.returns(true)

    # Create and process the email without expecting a bounce
    inbound_email = create_inbound_email_with_attachment(
      to: 'proof@example.com',
      from: @constituent.email,
      subject: 'Proof Document',
      body: 'Please find my proof attached.',
      attachment_path: file_path,
      content_type: 'application/pdf'
    )

    # Process the email (this should not bounce if validation is stubbed)
    assert_nothing_raised do
      inbound_email.route
    end

    # Clean up
    FileUtils.rm_f(file_path)
  end

  test 'handles emails with multiple recipients' do
    # Create a temporary file for testing
    file_path = Rails.root.join('tmp/income_proof.pdf')
    File.write(file_path, 'This is a test PDF file')

    # We need to stub ProofAttachmentValidator to pass validation
    ProofAttachmentValidator.stubs(:validate!).returns(true)

    # Stub the attach_proof method to prevent actual attachment but still track calls
    ProofSubmissionMailbox.any_instance.expects(:attach_proof).at_least_once.returns(true)

    # Capture the constituent's email in a local variable before the Mail.new block
    # to ensure it's resolved in the correct scope.
    current_constituent_email = @constituent.email

    mail = Mail.new do
      from current_constituent_email # Use the local variable
      to ['proof@example.com', 'support@example.com', 'admin@example.com']
      subject 'Income Proof Submission'

      text_part do
        body 'Please find my income proof attached.'
      end

      add_file filename: 'income_proof.pdf', content: File.read(file_path)
    end

    # Create and process the inbound email
    inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.to_s)

    # Process without expecting a bounce
    assert_nothing_raised do
      inbound_email.route
    end

    # Clean up
    FileUtils.rm_f(file_path)
  end

  test 'handles emails with special characters in subject and body' do
    # Create a temporary file for testing
    file_path = Rails.root.join('tmp/income_proof.pdf')

    begin
      # Ensure the tmp directory exists
      FileUtils.mkdir_p(File.dirname(file_path))

      # Create the file with some content
      File.write(file_path, 'This is a test PDF file')

      # Verify file creation with simple retry logic
      retries = 0
      while !File.exist?(file_path) && retries < 5
        sleep(0.1)
        retries += 1
      end

      assert File.exist?(file_path), "Test file was not created at #{file_path}"
      assert File.size(file_path).positive?, "Test file is empty at #{file_path}"

      # We need to stub ProofAttachmentValidator to pass validation
      ProofAttachmentValidator.stubs(:validate!).returns(true)

      # Stub the attach_proof method to prevent actual attachment but still track calls
      ProofSubmissionMailbox.any_instance.expects(:attach_proof).at_least_once.returns(true)

      inbound_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: @constituent.email,
        subject: 'Income Proof Submission - 特殊文字 - üñîçødé',
        body: 'Please find my income proof attached. 特殊文字 üñîçødé',
        attachment_path: file_path,
        content_type: 'application/pdf'
      )

      # Process without expecting a bounce
      assert_nothing_raised do
        inbound_email.route
      end
    ensure
      # Ensure cleanup happens even if test fails
      FileUtils.rm_f(file_path) if file_path
    end
  end
end
