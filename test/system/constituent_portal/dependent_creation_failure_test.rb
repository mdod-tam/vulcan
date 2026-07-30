# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module ConstituentPortal
  # Visible evidence for the failed-creation re-render. Rollback restores the attempted dependent
  # to a new record while keeping the synthetic contact the guardian strategy wrote into it, so
  # re-rendering that object would put internal placeholders in front of the guardian and let an
  # unchanged retry store them as dependent-owned contact.
  class DependentCreationFailureTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      @guardian = create(
        :constituent,
        first_name: 'Portal',
        last_name: 'Guardian',
        email: "portal-guardian-#{SecureRandom.hex(3)}@example.com",
        phone: '555-111-2222'
      )
      # A soft-match candidate, so creation reaches the review-case step that fails below.
      @existing = create(
        :constituent,
        first_name: 'Softmatch',
        last_name: 'Candidate',
        date_of_birth: Date.new(2010, 5, 15),
        email: "softmatch-#{SecureRandom.hex(3)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}"
      )
      system_test_sign_in(@guardian)
    end

    test 'a failed dependent creation keeps the guardian contact choice and hides internal placeholders' do
      DuplicateReviewCases::CreateService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'case creation failed', data: {})
      )

      visit new_constituent_portal_dependent_path
      fill_in 'First Name', with: @existing.first_name
      fill_in 'Last Name', with: @existing.last_name
      fill_in 'Date of Birth', with: '05/15/2010'
      check 'Hearing'
      select 'Parent', from: 'Your Relationship to Dependent'

      # Guardian contact strategy: leave dependent contact blank and use the guardian's own.
      check 'use_guardian_email_checkbox'
      check 'use_guardian_phone_checkbox'
      take_evidence_screenshot('dependent-create-guardian-contact-selected', full: true, html: true)

      click_button 'Add Dependent'

      assert_text(/failed to create dependent/i)

      # The guardian sees what they submitted, not the placeholders the attempt generated.
      assert_no_text '@system.matvulcan.local'
      assert_no_selector "input[value*='@system.matvulcan.local']"
      assert_no_selector "input[value^='000-']"
      assert find_by_id('use_guardian_email_checkbox').checked?,
             'the guardian email choice must survive the failed attempt'
      assert find_by_id('use_guardian_phone_checkbox').checked?,
             'the guardian phone choice must survive the failed attempt'
      take_evidence_screenshot('dependent-create-failure-preserves-guardian-contact', full: true, html: true)
    end
  end
end
