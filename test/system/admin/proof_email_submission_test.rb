# frozen_string_literal: true

require 'application_system_test_case'
require 'support/action_mailbox_test_helper'

module Admin
  class ProofEmailSubmissionTest < ApplicationSystemTestCase
    include ActionMailboxTestHelper

    setup do
      # Set up policies required by ProofSubmissionMailbox
      setup_fpl_policies

      # Create users and application using factories with unique email
      @admin = create(:admin)
      @constituent_email = "constituent_#{Time.now.to_i}_#{rand(10_000)}@example.com"
      @constituent = create(:constituent, email: @constituent_email)
      @application = create(:application, :old_enough_for_new_application, user: @constituent)

      # Set the application to a status that allows for proof submission.
      # The ProofSubmissionMailbox bounces emails for applications that are not in an active state (e.g. 'draft').
      @application.update!(status: :awaiting_proof)

      # Set up ApplicationMailbox routing for testing
      ApplicationMailbox.instance_eval do
        routing(/proof@/i => :proof_submission)
      end

      # Log in as admin
      system_test_sign_in(@admin)
      wait_for_turbo
    end

    test 'email ingestion attaches proof and shows indicator' do
      # Create a temporary file for testing
      file_path = Rails.root.join('tmp/income_proof.pdf')
      # Ensure file is large enough to pass size validations (> 1KB)
      File.write(file_path, 'This is a test PDF file that is larger than one kilobyte to ensure it passes all attachment validations in the mailbox. ' * 20)

      # Create and process an inbound email
      inbound_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: @constituent_email,
        subject: 'Income Proof Submission',
        body: 'Please find my income proof attached.',
        attachment_path: file_path,
        content_type: 'application/pdf'
      )

      inbound_email.route

      # Visit the application page and wait for content to load
      visit admin_application_path(@application)
      wait_for_turbo

      # Check if the proof is visible and marked as email-submitted
      assert_text 'Income Proof'
      assert_text '(via email)'

      # Clean up
      FileUtils.rm_f(file_path)
    end

    test 'email ingestion works under truncation and indicator is present' do
      # Prepare unique data and file outside the truncation block
      admin = create(:admin)
      unique_email = "constituent_#{Time.now.to_i}_#{SecureRandom.hex(4)}@example.com"
      constituent = create(:constituent, email: unique_email)
      app = create(:application, :old_enough_for_new_application, user: constituent)
      app.update!(status: :awaiting_proof)
      file_path = Rails.root.join('tmp/income_proof.pdf')
      File.write(file_path, 'This is a test PDF file that is larger than one kilobyte to ensure it passes all attachment validations in the mailbox. ' * 20)

      # Route the inbound email (system tests run with truncation globally)
      inbound_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: unique_email,
        subject: 'Income Proof Submission',
        body: 'Please find my income proof attached.',
        attachment_path: file_path,
        content_type: 'application/pdf'
      )
      inbound_email.route

      # UI interactions AFTER truncation to avoid target disposal during cleanup
      system_test_sign_in(admin)
      wait_for_turbo

      visit admin_application_path(app)
      wait_for_turbo

      assert_text 'Income Proof'
      assert_text '(via email)'

      FileUtils.rm_f(file_path)
    end

    test 'admin can view multiple proof types submitted via separate emails' do
      # Prepare unique data and files outside truncation
      # Use existing admin from setup instead of creating a new one
      admin = @admin
      unique_email = "constituent_truncation_#{Time.now.to_i}_#{rand(10_000)}@example.com"
      constituent = create(:constituent, email: unique_email)
      app = create(:application, :old_enough_for_new_application, user: constituent)
      app.update!(status: :awaiting_proof)

      income_file_path = Rails.root.join('tmp/income_proof.pdf')
      residency_file_path = Rails.root.join('tmp/residency_proof.pdf')
      File.write(income_file_path, 'This is income proof file, padded to be larger than 1KB. ' * 50)
      File.write(residency_file_path, 'This is residency proof file, padded to be larger than 1KB. ' * 50)

      # Route both emails (global truncation already used for system tests)
      income_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: unique_email,
        subject: 'Income Proof Submission',
        body: 'Please find my income proof attached.',
        attachment_path: income_file_path,
        content_type: 'application/pdf'
      )
      income_email.route

      residency_email = create_inbound_email_with_attachment(
        to: 'proof@example.com',
        from: unique_email,
        subject: 'Residency Proof Submission',
        body: 'Please find my residency proof attached.',
        attachment_path: residency_file_path,
        content_type: 'application/pdf'
      )
      residency_email.route

      # UI interactions AFTER truncation
      system_test_sign_in(admin)
      visit_admin_application_with_retry(app, max_retries: 3, user: admin)
      # Use assert_text with wait parameter instead of using_wait_time wrapper
      assert_text 'Income Proof', wait: 20
      assert_text 'Residency Proof', wait: 20

      with_browser_rescue(max_retries: 3) do
        wait_for_page_stable
        assert_text '(via email)', count: 2
        assert_text 'income_proof.pdf'
        assert_text 'residency_proof.pdf'
      end

      FileUtils.rm_f(income_file_path)
      FileUtils.rm_f(residency_file_path)
    end
  end
end
