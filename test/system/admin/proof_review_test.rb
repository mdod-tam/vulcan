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
                            disability_certification_status: 'approved') # Hide certification request controls.

      attach_cleared_proof(@application, :income_proof)
      attach_cleared_proof(@application, :residency_proof)

      system_test_sign_in(@admin, bypass_mfa_enrollment: true)
    end

    test 'a rejected save keeps the explanation and an enabled retry inside the open dialog' do
      visit_admin_application_with_retry(@application, user: @admin, bypass_mfa_enrollment: true)
      open_proof_rejection_modal('income', timeout: 15)
      decision_key = find('#proofRejectionModal input[name="decision_key"]', visible: :all).value
      target_id = @application.income_proof.blob.id
      assert decision_key.present?
      assert_equal target_id.to_s, find('#proofRejectionModal input[name="reviewed_blob_id"]', visible: :all).value
      failure = BaseService::Result.new(success: false, message: 'The review could not be saved. Try again.', data: {})
      ProofReviewService.any_instance.stubs(:call).returns(failure)

      submit_custom_proof_rejection('The document needs a legible signature.')

      within('#proofRejectionModal[open]') do
        assert_selector '[role="alert"]', text: 'The review could not be saved. Try again.'
        assert_field 'Reason for Rejection', with: 'The document needs a legible signature.', disabled: false
        assert_selector 'input[name="rejection_reason_code"][value="other"]', visible: :all
        assert_button 'Submit', disabled: false
        assert_selector "input[name='decision_key'][value='#{decision_key}']", visible: :all
        assert_selector "input[name='reviewed_blob_id'][value='#{target_id}']", visible: :all
      end
      assert_equal 'not_reviewed', @application.reload.income_proof_status
      take_screenshot('proof-rejection-failed-draft', full: true, html: true)

      ProofReviewService.any_instance.unstub(:call)
      within('#proofRejectionModal') do
        reason_button = first('button[data-action="click->rejection-form#selectPredefinedReason"][data-reason-code]', minimum: 1)
        reason_text = reason_button['data-reason-text']
        reason_code = reason_button['data-reason-code']
        reason_button.click
        assert_field 'Reason for Rejection', with: reason_text
        assert_selector "input[name='rejection_reason_code'][value='#{reason_code}']", visible: :all
        find('button[data-action="click->rejection-form#selectOther"]').click
        fill_in 'Reason for Rejection', with: 'The replacement needs a legible date.'
        click_button 'Submit'
      end
      assert_no_selector '#proofRejectionModal[open]', wait: 15
      assert_equal 'rejected', @application.reload.income_proof_status
      assert_equal 'The replacement needs a legible date.', @application.proof_reviews.order(:id).last.rejection_reason
      assert_equal decision_key, @application.proof_reviews.recent.first.decision_key
      assert_equal target_id, @application.proof_reviews.recent.first.reviewed_blob_id
      take_screenshot('proof-rejection-retry-saved', full: true, html: true)
    ensure
      ProofReviewService.any_instance.unstub(:call)
    end
  end
end
