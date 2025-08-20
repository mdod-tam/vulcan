# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class AuditLogsTest < ApplicationSystemTestCase
    setup do
      # Force a clean browser session for each test
      Capybara.reset_sessions!

      @admin = users(:admin_david)

      # Create application with explicit attributes to ensure it exists
      @application = create(:application,
                            user: users(:confirmed_user),
                            status: 'in_progress',
                            household_size: 2,
                            annual_income: 30_000,
                            maryland_resident: true,
                            self_certify_disability: true,
                            income_proof_status: 'not_reviewed',
                            residency_proof_status: 'not_reviewed')

      # Store original environment variables
      @original_mailer_host = ENV.fetch('MAILER_HOST', nil)

      # Force attach both proofs and ensure correct statuses
      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      # Ensure the application is saved with proofs attached
      @application.reload

      # Set the MAILER_HOST environment variable for the test
      ENV['MAILER_HOST'] = 'example.com'

      # Don't sign in during setup - let each test handle its own authentication
      # This ensures each test starts with a clean authentication state
    end

    teardown do
      # Ensure any open modals are closed
      begin
        if has_selector?('#incomeProofReviewModal', visible: true)
          within('#incomeProofReviewModal') do
            click_button 'Close' if has_button?('Close')
          end
        end

        if has_selector?('#residencyProofReviewModal', visible: true)
          within('#residencyProofReviewModal') do
            click_button 'Close' if has_button?('Close')
          end
        end
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
        # Browser might be in a bad state, reset it
        Capybara.reset_sessions!
      end

      # Restore original environment variables
      ENV['MAILER_HOST'] = @original_mailer_host

      # Always ensure clean session state between tests
      Capybara.reset_sessions!
    end

    test 'audit logs correctly show proof review actions without duplicates' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)

      # Use intelligent waiting - assert_selector will wait automatically
      assert_selector '#attachments-section', wait: 15

      # Open the income proof review modal
      # Open modal using the standardized helper for overlap safety
      click_review_proof_and_wait('income', timeout: 20)

      # Approve the income proof within the modal
      within '#incomeProofReviewModal' do
        assert_selector 'button', text: 'Approve'
        click_button 'Approve'
      end

      # Wait for success notification - implicit waiting
      assert_notification('Income proof approved successfully.')

      # Ensure modal is closed - implicit waiting
      assert_no_selector '#incomeProofReviewModal', visible: true

      # Check audit logs section - handle duplicate IDs by using the first visible one
      audit_logs_section = first('#audit-logs', visible: true)
      within audit_logs_section do
        # Check that we have the admin review entry - implicit waiting
        assert_text 'Admin Review'
        assert_text @admin.full_name
        assert_text 'Admin approved Income proof'

        # Check that we don't have duplicate entries
        assert_selector 'tbody tr'
        income_approved_rows = all('tbody tr').select do |tr|
          tr.text.include?('Income proof') && tr.text.include?('approved')
        end
        assert_equal 1, income_approved_rows.count, 'Expected only one entry for Income proof approval'
      end
    end

    private

    def count_audit_log_entries
      # Use has_selector? with intelligent waiting and handle duplicate IDs
      if has_selector?('#audit-logs')
        audit_logs_section = first('#audit-logs', visible: true)
        within audit_logs_section do
          return all('tbody tr').count
        end
      else
        # If the section doesn't exist, return 0
        0
      end
    end
  end
end
