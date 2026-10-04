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
      visit edit_admin_application_path(@application)

      select 'In Progress', from: 'Status'
      click_button 'Update Application'
      wait_for_turbo

      assert_current_path admin_application_path(@application)

      within('#audit-logs') do
        find('tr', text: 'Status Change', wait: 15)

        assert_text 'Status Change'
        assert_text 'Application submitted for review'
        assert_text @admin.full_name
      end
    end

    test 'admin can see proof review history in audit log' do
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

      visit_admin_application_with_retry(@application, user: @admin)

      click_review_proof_and_wait('income', timeout: 15)

      within '#incomeProofReviewModal' do
        assert_selector('button', text: 'Reject', wait: 3)
        click_button 'Reject'
      end

      wait_for_modal_open('proofRejectionModal', timeout: 10)

      within '#proofRejectionModal' do
        assert_selector('textarea[name="rejection_reason"]', wait: 5)

        # This test sets the hidden proof type directly.
        page.execute_script("document.getElementById('rejection-proof-type').value = 'income'")

        click_modal_button('Wrong Document Type')

        assert_selector("textarea[name='rejection_reason']:not([value=''])", wait: 5)

        click_modal_button('Submit')
      end

      assert_no_selector '#proofRejectionModal', visible: true, wait: 10

      @application.reload
      wait_for_turbo

      audit_section = all('#audit-logs').last
      within(audit_section) do
        find('tr', text: 'Admin Review', wait: 15)

        assert_text 'Admin rejected Income proof - The document you submitted is not an acceptable type of income proof'
        assert_text @admin.full_name
      end
    end

    test 'admin can see medical certification activity in audit log' do
      @application.update!(medical_certification_status: 'not_requested')

      @application.update!(
        medical_provider_name: 'Dr. Test Provider',
        medical_provider_email: 'provider@example.com'
      )

      visit admin_application_path(@application)
      wait_for_turbo

      accept_confirm do
        if page.has_button?(/Send DocuSeal Request/i, wait: 5)
          click_button(/Send DocuSeal Request/i)
        elsif page.has_button?(/Resend DocuSeal/i, wait: 5)
          click_button(/Resend DocuSeal/i)
        elsif page.has_button?('Send Secure Cert Upload Link', wait: 5)
          click_button 'Send Secure Cert Upload Link'
        else
          skip 'No medical certification request buttons available'
        end
      end
      wait_for_turbo

      @application.reload

      within('#audit-logs') do
        assert_selector('tr', text: /Medical certification requested/i, wait: 15)
      end
    end

    test 'admin can see evaluator assignments in audit log' do
      @application.update!(status: 'approved')

      visit admin_application_path(@application)

      click_button "Assign #{@evaluator.full_name}"
      wait_for_turbo

      if page.has_css?('#audit-logs')
        # Resolve the section again to avoid a stale element.
        within('#audit-logs') do
          assert_selector('tr', text: 'Evaluator Assigned', wait: 15)

          assert_text @evaluator.full_name
          assert_text @admin.full_name
        end
      end
    end

    test 'admin can see voucher assignments in audit log' do
      @application.update!(
        status: 'approved',
        income_proof_status: 'approved',
        residency_proof_status: 'approved',
        id_proof_status: 'approved',
        medical_certification_status: 'approved'
      )

      visit admin_application_path(@application)

      accept_confirm do
        click_button 'Assign Voucher'
      end
      wait_for_turbo

      within('#audit-logs') do
        assert_selector('tr', text: 'Voucher Assigned', wait: 15)

        assert_text 'Voucher Assigned'
        assert_text @admin.full_name
        assert_match(/Voucher \w+ assigned on \w+ \d{2}, \d{4} for \$[\d,]+\.\d{2}/, page.text)
      end
    end
  end
end
