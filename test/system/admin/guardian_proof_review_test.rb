# frozen_string_literal: true

require 'application_system_test_case'

module AdminTests
  class GuardianProofReviewTest < ApplicationSystemTestCase
    setup do
      # Force a clean browser session for each test
      Capybara.reset_sessions!

      @admin = create(:admin)
      @application = create(:application, :in_progress_with_pending_proofs, :submitted_by_guardian, :old_enough_for_new_application)

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

      # Always ensure clean session state between tests
      Capybara.reset_sessions!
    end

    test 'displays guardian alert in income proof review modal' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      # Wait for page to load with resilient assertion
      assert_text(/Application Details|Application #/i, wait: 30)

      # Use intelligent waiting - assert_selector will wait automatically
      assert_selector '#attachments-section', wait: 15
      assert_selector '#attachments-section', text: 'Income Proof'
      assert_selector '#attachments-section', text: 'Residency Proof'

      # Open the income proof review modal using direct trigger to avoid overlap
      # Use fresh find and JS trigger to avoid overlap
      find("button[data-modal-id='incomeProofReviewModal']", visible: :all, wait: 15).trigger('click')
      wait_for_modal_open('incomeProofReviewModal', timeout: 15)

      # Verify the guardian alert is displayed using resilient checks
      assert_selector '#incomeProofReviewModal', text: 'Guardian Application', wait: 15
      assert_selector '#incomeProofReviewModal', text: 'This application was submitted by a Guardian User (parent) on behalf of a dependent', wait: 15
      assert_selector '#incomeProofReviewModal', text: 'Please verify this relationship when reviewing these proof documents', wait: 15

      within('#incomeProofReviewModal') do
        find('button', text: 'Close', visible: :all, wait: 10).trigger('click')
      end
    end

    test 'displays guardian alert in residency proof review modal' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      # Wait for page to load with resilient assertion
      assert_text(/Application Details|Application #/i, wait: 30)

      # Use intelligent waiting - assert_selector will wait automatically
      assert_selector '#attachments-section', wait: 15
      assert_selector '#attachments-section', text: 'Income Proof'
      assert_selector '#attachments-section', text: 'Residency Proof'

      # Open the residency proof review modal
      find("button[data-modal-id='residencyProofReviewModal']", visible: :all, wait: 15).trigger('click')
      wait_for_modal_open('residencyProofReviewModal', timeout: 15)

      # Verify the guardian alert is displayed using resilient checks
      assert_selector '#residencyProofReviewModal', text: 'Guardian Application', wait: 15
      assert_selector '#residencyProofReviewModal', text: 'This application was submitted by a Guardian User (parent) on behalf of a dependent', wait: 15
      assert_selector '#residencyProofReviewModal', text: 'Please verify this relationship when reviewing these proof documents', wait: 15

      within('#residencyProofReviewModal') do
        find('button', text: 'Close', visible: :all, wait: 10).trigger('click')
      end
    end

    test 'does not display guardian alert for non-guardian applications' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)

      # Create a regular application (not from a guardian) with all required fields
      regular_constituent = create(:constituent,
                                   email: "regular_test_#{Time.now.to_i}_#{rand(10_000)}@example.com",
                                   first_name: 'Regular',
                                   last_name: 'User')
      regular_application = create(:application,
                                   :in_progress_with_pending_proofs,
                                   :old_enough_for_new_application,
                                   user: regular_constituent,
                                   household_size: 2,
                                   annual_income: 30_000,
                                   maryland_resident: true,
                                   self_certify_disability: true)

      # Manually attach proofs since the factory trait isn't working
      regular_application.income_proof.attach(
        io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
        filename: 'income_proof.pdf',
        content_type: 'application/pdf'
      )
      regular_application.residency_proof.attach(
        io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
        filename: 'residency_proof.pdf',
        content_type: 'application/pdf'
      )

      # Ensure proofs are properly saved and processed
      regular_application.reload

      with_browser_rescue { visit admin_application_path(regular_application) }
      wait_for_page_stable

      # Wait for basic page structure first using a stable content anchor
      assert_text(/Application Details|Application #/i, wait: 30)

      # Use intelligent waiting - assert_selector will wait automatically
      assert_selector '#attachments-section', wait: 15
      assert_selector '#attachments-section', text: 'Income Proof'
      assert_selector '#attachments-section', text: 'Residency Proof'

      # Open the income proof review modal
      click_review_proof_and_wait('income', timeout: 15)

      # Verify the guardian alert is not displayed
      within '#incomeProofReviewModal' do
        assert_no_text 'Guardian Application'
        assert_no_text 'This application was submitted by a'
        assert_no_text 'on behalf of a minor'
      end

      # Close the modal
      within '#incomeProofReviewModal' do
        click_button 'Close'
      end

      # Open the residency proof review modal
      click_review_proof_and_wait('residency', timeout: 15)

      # Verify the guardian alert is not displayed
      within '#residencyProofReviewModal' do
        assert_no_text 'Guardian Application'
        assert_no_text 'This application was submitted by a'
        assert_no_text 'on behalf of a minor'
      end
    end
  end
end
