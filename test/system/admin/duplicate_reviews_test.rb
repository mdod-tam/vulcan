# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class DuplicateReviewsTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      @admin = create(:admin)
      @subject = create(
        :constituent,
        first_name: 'Portal',
        last_name: 'Registrant',
        email: "portal-registrant-#{SecureRandom.hex(3)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: true
      )
      @candidate = create(
        :constituent,
        first_name: 'Existing',
        last_name: 'Account',
        email: "existing-account-#{SecureRandom.hex(3)}@example.com",
        phone: '410-555-0198',
        phone_type: 'text'
      )
      @review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      @review_case.duplicate_review_case_candidates.create!(
        candidate_user: @candidate,
        match_reason: 'name_dob',
        snapshot: {}
      )

      system_test_sign_in(@admin)
    end

    # Resolving as "needs more information" used to close the case, which released the constituent's
    # submission gate and cleared the subject's review flag -- removing the case from the queue and
    # badges that staff rely on to come back to it. The determination is no longer offered, and the
    # form says what to do instead.
    test 'the resolve form does not offer a determination that would close an undecided case' do
      visit admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'

      within 'select[name=determination]' do
        assert_selector 'option[value=keep_separate]'
        assert_no_selector 'option[value=needs_more_information]'
      end
      assert_text 'Still gathering information? Leave this case open instead of resolving it.'

      take_evidence_screenshot('duplicate-review-resolve-form-no-nonterminal-determination',
                               full: true, html: true)
    end

    test 'admin merge form keeps login authority fixed and gates conditional phone type' do
      visit admin_duplicate_reviews_path
      assert_selector '[data-testid="duplicate-review-queue"]'
      assert_selector '[data-testid="duplicate-review-case-row"]', text: @subject.full_name
      take_evidence_screenshot('duplicate-review-queue-current', full: true, html: true)

      click_link 'Compare records'
      assert_current_path admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'
      find('summary', text: 'Merge these two records').click

      form_selector = 'form[data-testid="duplicate-merge-form"]'
      assert_selector form_selector
      assert_no_selector "#{form_selector} input[type='radio'][name='contact[email]']"

      prefix = "duplicate-review-#{@review_case.id}-candidate-#{@candidate.id}"
      within(form_selector) do
        choose "#{prefix}-canonical-#{@candidate.id}"
        choose "#{prefix}-phone-source-#{@candidate.id}"
        choose "#{prefix}-address-source-#{@candidate.id}"
        choose "#{prefix}-delivery-source-#{@candidate.id}"
        fill_in "#{prefix}-rationale", with: 'Identity verified from the registration evidence and support call.'
        check "#{prefix}-same-person-confirmed"

        assert_selector "##{prefix}-phone-type[required][aria-required='true']"
        assert_selector "input[type='submit'][disabled]"

        # Each decision group carries its own accessible name, and the gate says which one is
        # still outstanding rather than only that something is.
        assert_selector 'fieldset > legend', text: 'Phone'
        assert_selector 'fieldset > legend', text: 'Address'
        assert_selector '[data-final-submit-gate-target="status"]', text: 'Still needed: Phone type.'
      end
      take_evidence_screenshot('duplicate-merge-real-phone-type-required', full: true, html: true)

      within(form_selector) do
        select 'Voice', from: "#{prefix}-phone-type"
        assert_selector "input[type='submit']:not([disabled])"
      end
      take_evidence_screenshot('duplicate-merge-ready-with-phone-type', full: true, html: true)

      within(form_selector) do
        choose "#{prefix}-phone-source-#{@subject.id}"
        # A control whose value is cleared on every update must not stay operable, so no real
        # phone surviving disables it outright rather than leaving a selection the gate would
        # silently discard. (A CSS `find` still locates it; only find_field filters on disabled.)
        phone_type = find("##{prefix}-phone-type")
        assert_equal 'false', phone_type['aria-required']
        assert_not phone_type[:required]
        assert phone_type.disabled?, 'phone type must not remain operable when no real phone survives'
        assert_equal '', phone_type.value
        assert_selector "input[type='submit']:not([disabled])"
      end
      take_evidence_screenshot('duplicate-merge-blank-phone-clears-phone-type', full: true, html: true)
    end
  end
end
