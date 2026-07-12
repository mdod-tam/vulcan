# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DuplicateReviewMergeTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin, email: "dup-merge-admin-#{SecureRandom.hex(4)}@example.com")
      @subject = create(:constituent, email: "dup-merge-subject-#{SecureRandom.hex(4)}@example.com")
      @candidate = create(:constituent, email: "dup-merge-candidate-#{SecureRandom.hex(4)}@example.com")
      @review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      @review_case.duplicate_review_case_candidates.create!(candidate_user: @candidate, match_reason: 'name_dob', snapshot: {})

      system_test_sign_in(@admin)
      visit admin_duplicate_review_path(@review_case)
      wait_for_turbo
    end

    test 'comparison table flags the differing email and the merge submit button gates on required choices' do
      assert_selector '[data-testid="record-comparison"]'
      within '[data-testid="record-comparison"]' do
        # The badge's source text is "Differs"; CSS renders it uppercase, and Capybara's
        # default text matching reflects rendered (post-CSS-transform) text in a real
        # browser driver, so match case-insensitively rather than depending on styling.
        assert_selector 'tr[data-diff="different"] span', text: /differs/i
      end

      find('summary', text: 'Merge these two records').click
      wait_for_stimulus_controller('final-submit-gate')

      dom_id_prefix = "merge_#{@candidate.id}"
      merge_form = find("##{dom_id_prefix}_rationale", visible: :all).ancestor('form')
      submit_button = merge_form.find('input[data-final-submit-gate-target="submitButton"]')
      assert submit_button.disabled?, 'submit button should start disabled until all required choices are made'

      choose "#{dom_id_prefix}_canonical_user_id_candidate"
      choose "#{dom_id_prefix}_contact_email_canonical"
      choose "#{dom_id_prefix}_contact_phone_canonical"
      choose "#{dom_id_prefix}_contact_address_canonical"
      select 'voice', from: "#{dom_id_prefix}_contact_phone_type"
      choose "#{dom_id_prefix}_delivery_choice_canonical"
      fill_in "#{dom_id_prefix}_rationale", with: 'Confirmed same person via support call, verified DOB and address.'
      check "#{dom_id_prefix}_same_person_confirmed"

      assert_not submit_button.disabled?, 'submit button should enable once every required choice is made'
    end

    test 'review outcome submit button enables from the single outcome control' do
      wait_for_stimulus_controller('final-submit-gate')
      resolve_submit = find('input[value="Save review outcome"]')
      assert resolve_submit.disabled?, 'resolve submit should start disabled'

      choose 'resolve_outcome_keep_separate'
      fill_in 'resolve_rationale', with: 'Reviewed and confirmed these are different people.'

      assert_not resolve_submit.disabled?, 'one outcome and a rationale should satisfy the review form'
    end

    test 'nonterminal review states remain visible and can return to normal review' do
      wait_for_stimulus_controller('final-submit-gate')
      choose 'resolve_outcome_needs_more_information'
      fill_in 'resolve_rationale', with: 'Waiting for the constituent to send identity documents.'
      click_button 'Save review outcome'

      assert_current_path admin_duplicate_reviews_path
      assert_text 'Awaiting information'
      take_screenshot('duplicate-review-queue-awaiting-information', html: true)

      click_link 'Review'
      assert_text 'This case is awaiting information'
      assert_selector '[data-testid="merge-unavailable"]'
      take_full_page_screenshot('duplicate-review-detail-awaiting-information', html: true)

      fill_in 'Why is this case ready for normal review?', with: 'Requested identity documents arrived.'
      click_button 'Return to normal review'
      assert_text 'Record review outcome'
      take_full_page_screenshot('duplicate-review-detail-open-review-outcome-form', html: true)

      choose 'resolve_outcome_fraud_or_security_review'
      fill_in 'resolve_rationale', with: 'A security specialist should review the conflicting identity evidence.'
      click_button 'Save review outcome'

      assert_current_path admin_duplicate_reviews_path
      assert_text 'Security review'
      take_screenshot('duplicate-review-queue-security-review', html: true)

      click_link 'Review'
      assert_text 'Security review does not suspend or deactivate either account.'
      assert_selector '[data-testid="merge-unavailable"]'
      take_full_page_screenshot('duplicate-review-detail-security-review', html: true)

      fill_in 'Why is this case ready for normal review?', with: 'Security specialist completed review.'
      click_button 'Return to normal review'
      choose 'resolve_outcome_keep_separate'
      fill_in 'resolve_rationale', with: 'Specialist confirmed these records belong to different people.'
      click_button 'Save review outcome'

      visit admin_duplicate_review_path(@review_case)
      assert_text 'Resolved — kept separate'
      assert_selector '[data-testid="resolution-summary"]'
      take_full_page_screenshot('duplicate-review-detail-resolved-keep-separate', html: true)
    end

    test 'merge without stored match signals requires explicit admin evidence confirmation' do
      @review_case.update!(metadata: { 'reason_codes' => [] })
      visit admin_duplicate_review_path(@review_case)
      wait_for_turbo

      find('summary', text: 'Merge these two records').click
      wait_for_stimulus_controller('final-submit-gate')

      dom_id_prefix = "merge_#{@candidate.id}"
      merge_form = find("##{dom_id_prefix}_rationale", visible: :all).ancestor('form')
      submit_button = merge_form.find('input[data-final-submit-gate-target="submitButton"]')

      choose "#{dom_id_prefix}_canonical_user_id_candidate"
      choose "#{dom_id_prefix}_contact_email_canonical"
      choose "#{dom_id_prefix}_contact_phone_canonical"
      choose "#{dom_id_prefix}_contact_address_canonical"
      select 'voice', from: "#{dom_id_prefix}_contact_phone_type"
      choose "#{dom_id_prefix}_delivery_choice_canonical"
      fill_in "#{dom_id_prefix}_rationale", with: 'Reviewed the available records and verified the identity.'
      check "#{dom_id_prefix}_same_person_confirmed"

      assert submit_button.disabled?, 'admin evidence confirmation should block merge when no signal was stored'
      assert_text 'No structured match signal was stored for this case.'

      check "#{dom_id_prefix}_reason_codes_admin_reviewed"
      assert_not submit_button.disabled?, 'explicit admin evidence confirmation should satisfy the merge evidence gate'
    end

    private

    def take_full_page_screenshot(name, html: false)
      @screenshot_artifact_label = name.presence
      wait_for_meaningful_page_content(timeout: 3) if respond_to?(:wait_for_meaningful_page_content)

      increment_unique
      # rubocop:disable Lint/Debugger -- screenshot capture is the purpose of this system-test helper
      page.save_screenshot(image_path, full: true)
      # rubocop:enable Lint/Debugger
      File.write(html_path, page.html) if html
      write_screenshot_sidecar(image_path, label: @screenshot_artifact_label, html_saved: html)
      puts screenshot_log_message(image_path)
      image_path
    ensure
      @screenshot_artifact_label = nil
    end
  end
end
