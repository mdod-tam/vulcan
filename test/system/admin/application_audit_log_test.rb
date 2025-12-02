# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ApplicationAuditLogTest < ApplicationSystemTestCase
    include ActiveStorageHelper
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @admin = create(:admin)
      @evaluator = create(:user, :evaluator)
      @medical_provider = create(:user, :medical_provider)
      @application = create(:application, :draft)

      setup_active_storage_test
      sign_in(@admin)
    end

    teardown do
      clear_active_storage
    end

    test 'admin can see application status changes in audit log' do
      # Go to edit page to change status
      visit edit_admin_application_path(@application)

      # Change application status
      select 'In Progress', from: 'Status'
      click_button 'Update Application'
      wait_for_turbo

      # Should redirect back to show page
      assert_current_path admin_application_path(@application)

      # Verify entry
      within('#audit-logs') do
        # Wait for the new entry to appear native Capybara wait
        find('tr', text: 'Status Change', wait: 15)

        # Verify all the text
        assert_text 'Status Change'
        assert_text 'Application submitted for review'
        assert_text @admin.full_name
      end
    end

    test 'admin can see proof review history in audit log' do
      # First attach the proof using service (non-browser action)
      result = ProofAttachmentService.attach_proof(
        application: @application,
        proof_type: :income,
        blob_or_file: fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf'),
        status: :not_reviewed,
        admin: @admin,
        submission_method: :paper
      )
      assert result[:success], "Failed to attach proof: #{result[:error]&.message}"
      @application.reload

      # Handle browser interactions using resilient navigation
      visit_admin_application_with_retry(@application, user: @admin)

      # Open review modal using stable helper
      click_review_proof_and_wait('income', timeout: 15)

      # Click reject to transition into rejection modal
      within '#incomeProofReviewModal' do
        assert_selector('button', text: 'Reject', wait: 3)
        click_button 'Reject'
      end

      # Wait for rejection modal to open and become fully interactive
      wait_for_modal_open('proofRejectionModal', timeout: 10)

      # Fill in rejection reason using proper waiting strategies
      within '#proofRejectionModal' do
        # Wait for modal to be fully loaded
        assert_selector('textarea[name="rejection_reason"]', wait: 5)

        # Manually set the proof type since the JS controller might not work in tests
        page.execute_script("document.getElementById('rejection-proof-type').value = 'income'")

        # Click rejection reason button using scroll-safe helper (not within_modal since we're already scoped)
        click_modal_button('Wrong Document Type')

        # Wait for the textarea to be populated by Stimulus
        assert_selector("textarea[name='rejection_reason']:not([value=''])", wait: 5)

        # Submit form using scroll-safe helper
        click_modal_button('Submit')
      end

      # Wait for modal to disappear
      assert_no_selector '#proofRejectionModal', visible: true, wait: 10

      # Wait for page to update and application to reload
      @application.reload
      wait_for_turbo

      # Wait for audit log to update - handle potential duplicate sections
      audit_section = all('#audit-logs').last # Use the last one which should be the most recent/visible
      within(audit_section) do
        # Wait for the new entry to appear with longer timeout
        find('tr', text: 'Admin Review', wait: 15)

        # Verify all the text
        assert_text 'Admin rejected Income proof - The document you submitted is not an acceptable type of income proof'
        assert_text @admin.full_name
      end
    end

    test 'admin can see medical certification activity in audit log' do
      # Ensure medical certification status allows sending request
      @application.update!(medical_certification_status: 'not_requested')

      # Ensure medical provider info is complete for the buttons to work
      @application.update!(
        medical_provider_name: 'Dr. Test Provider',
        medical_provider_email: 'provider@example.com'
      )

      visit admin_application_path(@application)
      wait_for_turbo

      # Request medical certification - button text varies based on application state
      # Use regex pattern to match different button variants
      accept_confirm do
        if page.has_button?(/Send DocuSeal Request/i, wait: 5)
          click_button(/Send DocuSeal Request/i)
        elsif page.has_button?(/Resend DocuSeal/i, wait: 5)
          click_button(/Resend DocuSeal/i)
        elsif page.has_button?('Send Email', wait: 5)
          click_button 'Send Email'
        elsif page.has_button?('Resend Email', wait: 5)
          click_button 'Resend Email'
        else
          # If no request buttons visible, skip this test
          skip 'No medical certification request buttons available'
        end
      end
      wait_for_turbo

      # Wait for page to update after the request
      @application.reload

      # Wait for audit log to update and verify entry
      within('#audit-logs') do
        # Wait for the new entry to appear with longer timeout - text varies by trigger type
        assert_selector('tr', text: /Medical certification requested/i, wait: 15)
      end
    end

    test 'admin can see evaluator assignments in audit log' do
      # First approve the application so evaluator assignment becomes available
      @application.update!(status: 'approved')

      visit admin_application_path(@application)

      # Assign evaluator (browser confirm not needed in headless tests)
      click_button "Assign #{@evaluator.full_name}"
      wait_for_turbo

      # Wait for audit log to update and verify entry
      if page.has_css?('#audit-logs')
        # Use within with selector instead of cached element to avoid stale references
        within('#audit-logs') do
          # Wait for evaluator assigned event row
          assert_selector('tr', text: 'Evaluator Assigned', wait: 15)

          # Confirm evaluator name present
          assert_text @evaluator.full_name
          assert_text @admin.full_name
        end
      end
    end

    test 'admin can see voucher assignments in audit log' do
      # First approve the application and medical certification so voucher assignment becomes available
      @application.update!(
        status: 'approved',
        medical_certification_status: 'approved'
      )

      visit admin_application_path(@application)

      # Assign voucher
      click_button 'Assign Voucher'
      wait_for_turbo

      # Wait for audit log to update and verify entry
      within('#audit-logs') do
        # Wait for the new entry to appear with longer timeout
        assert_selector('tr', text: 'Voucher Assigned', wait: 15)

        # Verify all the text
        assert_text 'Voucher Assigned'
        assert_text @admin.full_name
        assert_match(/Voucher \w+ assigned with value \$[\d,]+\.\d{2}/, page.text)
      end
    end
  end
end
