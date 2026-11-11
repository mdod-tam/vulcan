# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class RejectionReasonsManagementTest < ApplicationSystemTestCase
    test 'admin adds a rejection reason in both languages and lands on its edit page' do
      sign_in(create(:admin), bypass_mfa_enrollment: true)
      visit admin_rejection_reasons_path
      click_link 'New Rejection Reason'
      assert_selector 'h1', text: 'New Rejection Reason'
      take_screenshot('rejection-reason-new-form', html: true, full: true)

      select 'ID', from: 'Proof type'
      fill_in 'Reason name', with: 'Other'
      fill_in 'Reason text (English)', with: 'Please send a clearer photo of your ID.'
      fill_in 'Reason text (Spanish)', with: 'Envíe una foto más clara de su identificación.'
      click_button 'Create Rejection Reason'
      assert_text 'Reason name is reserved'
      assert_field 'Reason text (English)', with: 'Please send a clearer photo of your ID.'
      assert_selector "#rejection_reason_name[aria-invalid='true']"
      assert_selector '#create-rejection-reason-name-error', text: 'Reason name is reserved'
      take_screenshot('rejection-reason-new-form-error', html: true, full: true)

      fill_in 'Reason name', with: 'Photo is blurry'
      click_button 'Create Rejection Reason'
      assert_text 'Rejection reason created in English and Spanish.'
      assert_field 'Reason Body (EN)', with: 'Please send a clearer photo of your ID.'
      assert_field 'Reason Body (ES)', with: 'Envíe una foto más clara de su identificación.'
      take_screenshot('rejection-reason-created', html: true, full: true)
      assert_equal %w[en es], RejectionReason.where(code: 'photo_is_blurry', proof_type: 'id').order(:locale).pluck(:locale)
    end
  end
end
