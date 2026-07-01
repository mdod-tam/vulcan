# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class PaperApplicationContactControlsTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin, email: "contact_controls_#{SecureRandom.hex(4)}@example.com")
      system_test_sign_in(@admin)
      visit new_admin_paper_application_path
      wait_for_turbo
    end

    test 'self applicant create-new flow exposes no-contact controls and Stimulus targets' do
      choose 'An Adult (applying for themselves)'
      wait_for_turbo

      click_button 'Create New Applicant'
      wait_for_turbo

      assert_selector '#no_email_address_checkbox', visible: true
      assert_selector '#no_phone_number_checkbox', visible: true
      assert_selector '[data-controller="contact-feedback"]', visible: :all
      assert_selector '[data-contact-feedback-target="emailWrapper"]', visible: true
      assert_selector '[data-contact-feedback-target="phoneWrapper"]', visible: true
      assert_selector '[data-contact-feedback-target="email"]', visible: true
      assert_selector '[data-contact-feedback-target="phone"]', visible: true
    end
  end
end
