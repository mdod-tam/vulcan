# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PaperApplicationRejectionTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      # Use the enhanced sign-in helper for better reliability with Cuprite
      system_test_sign_in(@admin)
      # Ensure we are on a page that requires authentication after sign-in
      visit admin_applications_path
      wait_for_turbo
      assert_selector 'h1', text: 'Dashboard' # Hidden semantic landmark for tests
    end

    test 'admin can see all rejection reasons for income proof' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Ensure the Proof Documents fieldset is visible before interacting
      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      # Select reject income proof
      find_by_id('reject_income_proof').click

      # Check that all income proof rejection reasons are available
      within('#income_proof_rejection select') do
        assert_selector 'option', text: 'Address Mismatch'
        assert_selector 'option', text: 'Expired Documentation'
        assert_selector 'option', text: 'Missing Name'
        assert_selector 'option', text: 'Wrong Document Type'
        assert_selector 'option', text: 'Missing Income Amount'
        assert_selector 'option', text: 'Income Exceeds Threshold'
        assert_selector 'option', text: 'Outdated Social Security Award Letter'
      end
    end

    test 'admin can see appropriate rejection reasons for residency proof' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Ensure the Proof Documents fieldset is visible before interacting
      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      # Select reject residency proof
      find_by_id('reject_residency_proof').click

      # Check that appropriate residency proof rejection reasons are available
      within('#residency_proof_rejection select') do
        assert_selector 'option', text: 'Address Mismatch'
        assert_selector 'option', text: 'Expired Documentation'
        assert_selector 'option', text: 'Missing Name'
        assert_selector 'option', text: 'Wrong Document Type'

        # These should NOT be available for residency proof
        assert_no_selector 'option', text: 'Missing Income Amount'
        assert_no_selector 'option', text: 'Income Exceeds Threshold'
        assert_no_selector 'option', text: 'Outdated Social Security Award Letter'
      end
    end

    test 'selecting a predefined rejection reason shows read-only content and hides custom note input' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Ensure the Proof Documents fieldset is visible before interacting
      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      # Select reject income proof
      find_by_id('reject_income_proof').click

      # Select a rejection reason
      select 'Missing Name', from: 'income_proof_rejection_reason'

      # Read-only rejection content should be shown
      assert_selector '#income_proof_reason_preview', visible: true
      assert_text 'Predefined reasons are read-only in this form.'
      assert_text 'Rejection Reasons'

      # Custom note input should not be visible for predefined reasons
      assert_no_selector "[name='income_proof_rejection_notes']", visible: true
    end

    test 'selecting Other allows admin to enter a custom rejection note' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Ensure the Proof Documents fieldset is visible before interacting
      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      # Select reject income proof
      find_by_id('reject_income_proof').click

      # Select Other to enable the custom note input
      select 'Other', from: 'income_proof_rejection_reason'

      custom_message = 'Please provide a document with your full legal name clearly visible.'
      notes_field = find("[name='income_proof_rejection_notes']", visible: true)
      notes_field.set(custom_message)

      assert_equal custom_message, notes_field.value
    end

    test 'language guidance reflects applicant locale for custom notes' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Switch applicant preferred language to Spanish
      select 'Spanish', from: 'constituent_locale'

      find_by_id('reject_income_proof').click
      select 'Other', from: 'income_proof_rejection_reason'

      assert_text 'Applicant prefers to receive Spanish communications. Please ensure any custom note is translated.'
    end

    test 'medical certification custom note copy is certificate-signer specific and stays English' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Applicant locale can be Spanish, but medical certification notes are for the certificate signer.
      select 'Spanish', from: 'constituent_locale'

      find_by_id('reject_medical_certification').click
      select 'Other', from: 'medical_certification_rejection_reason'

      assert_text 'Disability certification communications are sent to the certificate signer in English.'
      assert_selector "label[for='medical_certification_rejection_notes']", text: 'Custom Note to Certificate Signer'
      assert_selector "[name='medical_certification_rejection_notes'][placeholder='Enter a custom rejection note for the certificate signer (in English)']"
    end
  end
end
