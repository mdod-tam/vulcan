# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProofRejectionReasonsTest < ApplicationSystemTestCase
    setup do
      Capybara.reset_sessions!

      setup_fpl_policies

      @admin = create(:admin)
      @user = create(:constituent, hearing_disability: true)
      @application = create(:application, :old_enough_for_new_application, user: @user)
      @application.update!(status: 'awaiting_proof')

      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      # Attached proofs determine whether review buttons appear.
      unless @application.income_proof.attached? && @application.residency_proof.attached?
        raise "Test setup failed: proofs not attached properly. Income: #{@application.income_proof.attached?}, Residency: #{@application.residency_proof.attached?}"
      end

      # Unreviewed proofs use the "Review Proof" label.
      @application.update!(
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed
      )

      # Existing reviews could affect this application's rejection state.
      @application.proof_reviews.destroy_all

      # Each test signs in after the browser session reset.
    end

    teardown do
      begin
        if has_selector?('#proofRejectionModal', visible: true, wait: 1)
          within('#proofRejectionModal') do
            click_button 'Cancel' if has_button?('Cancel', wait: 1)
          end
        end

        if has_selector?('#incomeProofReviewModal', visible: true, wait: 1)
          within('#incomeProofReviewModal') do
            click_button 'Close' if has_button?('Close', wait: 1)
          end
        end

        if has_selector?('#residencyProofReviewModal', visible: true, wait: 1)
          within('#residencyProofReviewModal') do
            click_button 'Close' if has_button?('Close', wait: 1)
          end
        end
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
        Capybara.reset_sessions!
      end

      Capybara.reset_sessions!
    end

    test 'admin can see all rejection reasons when rejecting income proof' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15

      assert_selector '#attachments-section', count: 1, wait: 15
      open_proof_rejection_modal('income', timeout: 15)

      within('#proofRejectionModal') do
        assert_selector('#rejection-proof-type', visible: false)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'income', proof_type_field.value

        # Common rejection reasons.
        assert_selector "button[data-reason-code='address_mismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-code='expired']", text: 'Expired'
        assert_selector "button[data-reason-code='missing_name']", text: 'Missing Name'
        assert_selector "button[data-reason-code='wrong_document']", text: 'Wrong Document Type'

        # Reasons specific to income proof.
        assert_selector "button[data-reason-code='missing_amount']", text: 'Missing Income Amount'
        assert_selector "button[data-reason-code='exceeds_threshold']", text: 'Income Exceeds Threshold'
        assert_selector "button[data-reason-code='outdated_ss_award']", text: 'Outdated Social Security Award Letter'

        # The current scope already selects the modal.
        click_modal_button('Cancel')
      end
    end

    test 'admin can see appropriate rejection reasons when rejecting residency proof' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)

      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector '#attachments-section', wait: 30

      wait_for_turbo if respond_to?(:wait_for_turbo)

      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      assert_selector 'button[data-modal-id="residencyProofReviewModal"]', count: 1, wait: 15

      open_proof_rejection_modal('residency', timeout: 15)

      within('#proofRejectionModal') do
        assert_selector('#rejection-proof-type', visible: false, wait: 15)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'residency', proof_type_field.value

        assert_selector "button[data-reason-code='address_mismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-code='expired']", text: 'Expired'
        assert_selector "button[data-reason-code='missing_name']", text: 'Missing Name'
        assert_selector "button[data-reason-code='wrong_document']", text: 'Wrong Document Type'

        assert_selector "button[data-reason-code='missing_amount']", visible: false
        assert_selector "button[data-reason-code='exceeds_threshold']", visible: false
        assert_selector "button[data-reason-code='outdated_ss_award']", visible: false

        click_modal_button('Cancel')
      end
    end

    test 'clicking a rejection reason button populates the reason field' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector '#attachments-section', wait: 30

      wait_for_turbo if respond_to?(:wait_for_turbo)

      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      assert_selector 'button[data-modal-id="incomeProofReviewModal"]', count: 1, wait: 15

      open_proof_rejection_modal('income', timeout: 15)

      within('#proofRejectionModal') do
        click_modal_button("button[data-reason-code='missing_name']")

        selected_button = find("button[data-reason-code='missing_name']")
        assert_equal 'true', selected_button['aria-pressed']

        assert_selector("textarea[name='rejection_reason']")

        reason_field = find("textarea[name='rejection_reason']")
        assert reason_field.value.present?, 'Rejection reason field should be populated'
        assert_includes reason_field.value, 'does not show your name'
        assert reason_field[:readonly], 'A predefined reason is read-only'

        assert_selector("[data-rejection-form-target='liveRegion']",
                        text: /Selected rejection reason: Missing Name/i,
                        visible: :all)

        click_modal_button('Cancel')
      end
    end

    test 'selecting Other in the proof rejection modal unlocks custom reason entry' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector '#attachments-section', wait: 30

      open_proof_rejection_modal('income', timeout: 15)

      within('#proofRejectionModal') do
        click_modal_button("[data-rejection-form-target='generalReasons'] button[aria-label='Enter a custom rejection reason']")

        reason_field = find("textarea[name='rejection_reason']")
        assert_nil reason_field[:readonly], 'Custom reason field should be editable after selecting Other'
        assert_selector "[data-rejection-form-target='languageNotice']", visible: true
        assert_selector "[data-rejection-form-target='codeStatus']", text: /Custom reason/
      end
    end

    test 'a predefined rejection reason cannot be edited; Other is the way to write one' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector '#attachments-section', wait: 20

      open_proof_rejection_modal('income', timeout: 15)

      within('#proofRejectionModal') do
        click_modal_button("button[data-reason-code='missing_name']")
        reason_field = find("textarea[name='rejection_reason']")
        predefined_text = reason_field.value
        assert predefined_text.present?, 'Field should be populated with the predefined reason'

        reason_field.send_keys(' edited')
        assert_equal predefined_text, reason_field.value

        click_modal_button('Cancel')
      end
    end
  end
end
