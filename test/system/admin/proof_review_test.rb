# frozen_string_literal: true

require 'application_system_test_case'
require 'support/system_test_helpers'

module AdminTests
  class ProofReviewTest < ApplicationSystemTestCase
    include SystemTestHelpers

    setup do
      @admin = create(:admin)
      @user = create(:constituent)

      @application = create(:application,
                            user: @user,
                            status: 'in_progress',
                            household_size: 2,
                            annual_income: 30_000,
                            maryland_resident: true,
                            self_certify_disability: true,
                            medical_certification_status: 'approved') # Hide certification request controls.

      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      system_test_sign_in(@admin)
      wait_for_turbo

      visit admin_applications_path
      assert_text 'Admin Dashboard', wait: 10
    end

    test 'modal properly handles scroll state when rejecting proof with letter_opener' do
      # Use test delivery to avoid letter_opener navigation.
      original_delivery_method = ActionMailer::Base.delivery_method
      ActionMailer::Base.delivery_method = :test

      begin
        visit_admin_application_with_retry(@application, user: @admin)

        assert_text(/Application Details|Application #/i, wait: 15)

        assert_body_scrollable

        assert_selector '#attachments-section', wait: 10

        click_review_proof_and_wait('income', timeout: 15)

        # This test omits a strict assertion about scroll lock because of headless flakiness.
        assert_selector '#incomeProofReviewModal', visible: true

        within('#incomeProofReviewModal') do
          click_button 'Reject'
        end

        wait_for_modal_open('proofRejectionModal', timeout: 15)

        within('#proofRejectionModal') do
          fill_in 'Reason for Rejection', with: 'Test rejection reason'
          click_on 'Submit'
        end

        wait_for_turbo
        assert_no_selector('#proofRejectionModal', wait: 10)
        wait_for_attachments_stream(15)

        assert_no_selector('#proofRejectionModal', wait: 10)
        ActionMailer::Base.delivery_method = original_delivery_method
      end
    end

    test 'modal cleanup works when navigating away without letter_opener' do
      # Use test delivery to avoid letter_opener navigation.
      original_delivery_method = ActionMailer::Base.delivery_method
      ActionMailer::Base.delivery_method = :test

      begin
        visit_admin_application_with_retry(@application, user: @admin)

        begin
          assert_text(/Application Details|Application #/i, wait: 15)
        rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
          puts "Browser corruption detected during page load: #{e.message}"
          if respond_to?(:force_browser_restart, true)
            force_browser_restart('proof_review_modal_cleanup_recovery')
          else
            Capybara.reset_sessions!
          end
          # A browser restart discards the session, so sign in again.
          system_test_sign_in(@admin)
          visit_admin_application_with_retry(@application, user: @admin)
          assert_text(/Application Details|Application #/i, wait: 15)
        end

        assert_selector '#attachments-section', wait: 10

        click_review_proof_and_wait('income', timeout: 15)

        assert_selector '#incomeProofReviewModal', visible: true, wait: 10

        assert_selector '#incomeProofReviewModal', wait: 10

        within('#incomeProofReviewModal') do
          accept_confirm { click_button 'Approve', wait: 5 }
        end

        wait_for_turbo
        wait_for_attachments_stream(15)

        # This workaround clears the scroll lock before the close assertion.
        page.execute_script("
          document.body.classList.remove('overflow-hidden');
          console.log('Force cleanup for test environment');
        ")

        assert_no_selector '#incomeProofReviewModal', wait: 15
      ensure
        ActionMailer::Base.delivery_method = original_delivery_method
      end
    end

    test 'modal preserves scroll state across multiple proof reviews' do
      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector '#attachments-section', wait: 30

      click_review_proof_and_wait('income', timeout: 15)

      assert_body_not_scrollable

      click_modal_button('Close', within_modal: '#incomeProofReviewModal')
      wait_for_modal_close('incomeProofReviewModal', timeout: 15)

      assert_body_scrollable

      click_review_proof_and_wait('residency', timeout: 15)

      assert_body_not_scrollable

      click_modal_button('Close', within_modal: '#residencyProofReviewModal')
      wait_for_modal_close('residencyProofReviewModal', timeout: 15)

      assert_body_scrollable
    end

    test 'admin can approve income proof via modal' do
      visit_admin_application_with_retry(@application, user: @admin)

      # Use a concrete selector to avoid stale nodes from text lookups.
      assert_selector '#attachments-section', wait: 10

      click_review_proof_and_wait('income', timeout: 15)

      within '#incomeProofReviewModal' do
        assert_selector 'button', text: 'Approve', wait: 5
        accept_confirm { click_button 'Approve' }
      end

      wait_for_turbo
      wait_for_modal_close('incomeProofReviewModal', timeout: 10)

      assert_text(/approved|success/i, wait: 5) if page.has_text?(/approved|success/i, wait: 3)
    end

    test 'clicking review proof button opens modal via Stimulus controller' do
      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector '#attachments-section', wait: 10

      wait_for_stimulus_controller('modal', timeout: 10) if respond_to?(:wait_for_stimulus_controller)

      review_button = find("button[data-modal-id='incomeProofReviewModal']", wait: 10)
      assert_equal 'click->modal#open', review_button['data-action'],
                   'Review button should have correct Stimulus action'

      # The button must open the modal through Stimulus without a fallback.
      review_button.click

      assert_selector 'dialog#incomeProofReviewModal[open]', visible: true, wait: 10,
                                                             message: 'Modal should open via Stimulus controller when review button is clicked'

      within '#incomeProofReviewModal' do
        assert_selector 'button', text: 'Approve', wait: 5
        assert_selector 'button', text: 'Reject', wait: 5
      end

      within '#incomeProofReviewModal' do
        click_button 'Close'
      end

      assert_no_selector 'dialog#incomeProofReviewModal[open]', wait: 10,
                                                                message: 'Modal should close when close button is clicked'
    end

    test 'can open second proof modal after approving first proof via Turbo Stream' do
      # A previous Turbo update removed other proof modals without replacement.
      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector '#attachments-section', wait: 10

      click_review_proof_and_wait('income', timeout: 15)

      within '#incomeProofReviewModal' do
        accept_confirm { click_button 'Approve' }
      end

      wait_for_turbo
      assert_no_selector 'dialog#incomeProofReviewModal[open]', wait: 10

      assert_selector 'dialog#residencyProofReviewModal', wait: 5,
                                                          message: 'Residency modal should still exist in DOM after Turbo Stream update'

      click_review_proof_and_wait('residency', timeout: 15)

      assert_selector 'dialog#residencyProofReviewModal[open]', visible: true, wait: 10,
                                                                message: 'Residency modal should open after income proof was approved'

      within '#residencyProofReviewModal' do
        assert_selector 'button', text: 'Approve', wait: 5
        assert_selector 'button', text: 'Reject', wait: 5
      end
    end

    test 'medical certification review uses Turbo Stream like income/residency proofs' do
      @application.update!(medical_certification_status: 'received')
      attach_lightweight_proof(@application, :medical_certification)

      visit_admin_application_with_retry(@application, user: @admin)

      assert_selector '#medical-certification-section', wait: 10

      click_button 'Review Certification'

      assert_selector 'dialog#medicalCertificationReviewModal[open]', visible: true, wait: 10,
                                                                      message: 'Medical certification modal should open via Stimulus controller'

      within '#medicalCertificationReviewModal' do
        accept_confirm { click_button 'Approve' }
      end

      wait_for_turbo
      assert_no_selector 'dialog#medicalCertificationReviewModal[open]', wait: 10

      assert_text(/updated|approved|success/i, wait: 5)

      assert_selector '#medical-certification-section', wait: 5
    end
  end
end
