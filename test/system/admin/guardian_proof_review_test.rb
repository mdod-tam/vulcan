# frozen_string_literal: true

require 'application_system_test_case'

module AdminTests
  class GuardianProofReviewTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
    end

    teardown do
      # Reset the browser session instead of interacting with open dialogs during teardown.
      Capybara.reset_sessions!
    end

    test 'guardian alert remains visible when reviewing income and residency in sequence' do
      application = create(:application, :in_progress_with_pending_proofs, :submitted_by_guardian, :old_enough_for_new_application)
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
      visit_admin_application_with_retry(application, user: @admin, bypass_mfa_enrollment: true)
      assert_selector '#attachments-section', text: 'Income Proof'
      assert_selector '#attachments-section', text: 'Residency Proof'

      %w[income residency].each do |proof_type|
        click_review_proof_and_wait(proof_type, timeout: 15)
        modal = "##{proof_type}ProofReviewModal"
        within modal do
          assert_text 'Guardian Application'
          assert_text 'This application was submitted by a Guardian User (parent) on behalf of a dependent'
          assert_text 'Please verify this relationship when reviewing these proof documents'
          click_button 'Close'
        end
        assert_no_selector "#{modal}[open]"
      end
    end

    test 'does not display guardian alert for non-guardian applications' do
      system_test_sign_in(@admin, bypass_mfa_enrollment: true)

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

      regular_application.income_proof.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'income_proof.pdf',
        content_type: 'application/pdf'
      )
      regular_application.residency_proof.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'residency_proof.pdf',
        content_type: 'application/pdf'
      )

      regular_application.reload

      visit_admin_application_with_retry(regular_application, user: @admin, bypass_mfa_enrollment: true)
      assert_text(/Application Details|Application #/i, wait: 30)

      assert_selector '#attachments-section', wait: 15
      assert_selector '#attachments-section', text: 'Income Proof'
      assert_selector '#attachments-section', text: 'Residency Proof'

      click_review_proof_and_wait('income', timeout: 15)

      within '#incomeProofReviewModal' do
        assert_no_text 'Guardian Application'
        assert_no_text 'This application was submitted by a'
        assert_no_text 'on behalf of a minor'
      end

      within '#incomeProofReviewModal' do
        click_button 'Close'
      end

      click_review_proof_and_wait('residency', timeout: 15)

      within '#residencyProofReviewModal' do
        assert_no_text 'Guardian Application'
        assert_no_text 'This application was submitted by a'
        assert_no_text 'on behalf of a minor'
      end
    end
  end
end
