# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PaperApplicationRejectionTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      system_test_sign_in(@admin)
      visit admin_applications_path
      wait_for_turbo
      assert_selector 'h1', text: 'Dashboard'
    end

    test 'admin can see all rejection reasons for income proof' do
      visit new_admin_paper_application_path
      wait_for_turbo

      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      find_by_id('reject_income_proof').click

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

      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      find_by_id('reject_residency_proof').click

      within('#residency_proof_rejection select') do
        assert_selector 'option', text: 'Address Mismatch'
        assert_selector 'option', text: 'Expired Documentation'
        assert_selector 'option', text: 'Missing Name'
        assert_selector 'option', text: 'Wrong Document Type'

        assert_no_selector 'option', text: 'Missing Income Amount'
        assert_no_selector 'option', text: 'Income Exceeds Threshold'
        assert_no_selector 'option', text: 'Outdated Social Security Award Letter'
      end
    end

    test 'selecting a predefined rejection reason shows read-only content and hides custom reason input' do
      visit new_admin_paper_application_path
      wait_for_turbo

      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      find_by_id('reject_income_proof').click

      select 'Missing Name', from: 'income_proof_rejection_reason'

      assert_selector '#income_proof_reason_preview', visible: true
      assert_text 'Predefined reasons are read-only in this form.'
      assert_text 'Rejection Reasons'

      assert_no_selector "[name='income_proof_custom_rejection_reason']", visible: true
    end

    test 'selecting Other allows admin to enter a custom rejection reason' do
      visit new_admin_paper_application_path
      wait_for_turbo

      assert_selector 'fieldset legend', text: 'Proof Documents', visible: true

      find_by_id('reject_income_proof').click

      select 'Other', from: 'income_proof_rejection_reason'

      custom_message = 'Please provide a document with your full legal name clearly visible.'
      reason_field = find("[name='income_proof_custom_rejection_reason']", visible: true)
      reason_field.set(custom_message)

      assert_equal custom_message, reason_field.value
    end

    test 'language guidance reflects applicant locale for custom reasons' do
      visit new_admin_paper_application_path
      wait_for_turbo

      select 'Spanish', from: 'constituent_locale'

      find_by_id('reject_income_proof').click
      select 'Other', from: 'income_proof_rejection_reason'

      assert_text 'Applicant prefers to receive Spanish communications. Please ensure any custom rejection reason is translated.'
    end

    test 'medical certification custom reason copy is certificate-signer specific and stays English' do
      visit new_admin_paper_application_path
      wait_for_turbo

      # Certification notes address the certificate signer in English, regardless of the applicant locale.
      select 'Spanish', from: 'constituent_locale'

      find_by_id('reject_medical_certification').click
      select 'Other', from: 'medical_certification_rejection_reason'

      assert_text 'Disability certification communications are sent to the certificate signer in English.'
      assert_selector "label[for='medical_certification_custom_rejection_reason']", text: 'Custom Rejection Reason'
      assert_selector "[name='medical_certification_custom_rejection_reason'][placeholder='Enter the rejection reason that will be sent to the certifying professional']"
    end
  end
end
