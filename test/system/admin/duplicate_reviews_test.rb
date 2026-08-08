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

    # A non-merge resolution means exactly one thing -- staff decided these are different people --
    # so the five-value determination control was offering a choice that did not exist. Resolving
    # recomputes two independent effects from remaining open cases: the submission gate releases
    # when no open registration soft-match case remains, and the review flag clears when no open
    # case of any source remains -- taking the subject off the queue badges staff rely on. Only a
    # completed identity decision may trigger either, so the outcome is server-owned and stated
    # plainly.
    test 'the resolve form states the fixed identity outcome instead of offering a choice' do
      visit admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'

      assert_no_selector 'select[name=determination]'
      # The action is server-owned, so the form offers no action control at all.
      within 'form[action$="/resolve"]' do
        assert_no_selector 'input[type=radio][name=resolution_action]'
        assert_no_selector 'legend', text: 'Action'
      end
      within '#identity-outcome' do
        assert_text 'Identity outcome: Keep records separate'
        assert_text 'represent different people'
        assert_text 'leave this case open instead of resolving it'
      end

      take_evidence_screenshot('duplicate-review-resolve-form-server-owned-outcome',
                               full: true, html: true)
    end

    # The resolution summary shows the outcome and the determination side by side, so the two must
    # agree. This is the state an admin is left looking at after deciding, and it is the only place
    # the status label is read back to them.
    test 'the resolved summary reports an outcome that agrees with the determination' do
      visit admin_duplicate_review_path(@review_case)

      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'confirmed these are different people'
        click_button 'Resolve case'
      end

      visit admin_duplicate_review_path(@review_case)
      within '[data-testid="resolution-summary"]' do
        assert_text 'Resolved without merge'
        assert_text 'Keep separate'
        assert_no_text 'Ignored'
      end
      assert_no_selector 'form[action$="/resolve"]'

      take_evidence_screenshot('duplicate-review-resolved-summary', full: true, html: true)
    end

    # The rollover guard has its own visible state. A page rendered before this shipped still has the
    # old determination select, so submitting it must not resolve the case under an intent the admin
    # no longer expressed. The request test proves the server refuses; this proves the admin can see
    # why and is left on a usable form.
    test 'a stale determination is refused with a visible alert and the case stays open' do
      visit admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'

      # Reconstruct the pre-5c-1 form: inject the determination control the old page carried.
      page.execute_script(<<~JS)
        const form = document.querySelector('form[action$="/resolve"]');
        const select = document.createElement('select');
        select.name = 'determination';
        select.innerHTML = '<option value="needs_more_information" selected>Needs more information</option>';
        form.appendChild(select);
      JS

      # Scoped: the merge form carries its own rationale field.
      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'still gathering documents'
        click_button 'Resolve case'
      end

      assert_text 'This form was out of date, so we reloaded the case.'
      assert_selector '[data-testid="duplicate-review-detail"]', text: 'Duplicate Review Case'
      assert @review_case.reload.open?, 'a stale submission must not resolve the case'
      assert_nil @review_case.resolved_at
      # The admin is left able to act, on the current form rather than the stale one.
      assert_selector '#identity-outcome', text: 'Keep records separate'
      assert_no_selector 'select[name=determination]'

      take_evidence_screenshot('duplicate-review-stale-determination-refused', full: true, html: true)
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
