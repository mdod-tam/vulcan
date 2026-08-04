# frozen_string_literal: true

require 'test_helper'

module Admin
  class DuplicateReviewsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: "admin-dup-#{SecureRandom.hex(4)}@example.com")
      @subject = create(:constituent, needs_duplicate_review: true)
      @candidate = create(:constituent, email: "cand-#{SecureRandom.hex(3)}@example.com")
      @review_case = open_case(@subject, @candidate)
      sign_in_for_integration_test(@admin)
    end

    test 'index lists open cases and legacy flags' do
      legacy = create(:constituent, needs_duplicate_review: true)
      get admin_duplicate_reviews_path
      assert_response :success
      assert_select '[data-testid="duplicate-review-case-row"]'
      assert_match legacy.full_name, response.body
      assert_select 'p', text: 'Review records that may belong to the same person.'
      assert_select '[data-testid="case-source"]', text: 'Found during registration'
      assert_select 'span', text: 'Name and date of birth match'
      assert_select 'span', text: '1 possible matching record'
      assert_select 'a', text: 'Compare records'
      assert_select '#legacy-heading', text: 'Other records flagged for review'
    end

    test 'show renders grouped comparison and forms' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="candidate-comparison"]'
      assert_select 'span', text: 'Name and date of birth match'
      assert_select 'form[data-controller~="final-submit-gate"][data-testid="duplicate-merge-form"]'
      assert_select 'input[name="contact[email]"]', count: 0
      assert_select 'select[data-final-submit-gate-conditional-required="phone-type"][aria-required="false"]'
      assert_select 'input[type="submit"][data-final-submit-gate-target="submitButton"]:not([disabled])'
    end

    # A non-merge resolution means exactly one thing, so the five-value control offered a fake
    # choice. The outcome is now server-owned and shown as static text; a one-option select would
    # have been no better. The enum keeps every value, because resolved cases already recorded with
    # them must still render.
    test 'the resolve form states the fixed outcome instead of offering a choice' do
      get admin_duplicate_review_path(@review_case)

      assert_response :success
      assert_select 'select[name=determination]', false,
                    'the determination must not be selectable'
      assert_select '#identity-outcome', text: /Keep records separate/
      assert_select '#identity-outcome', text: /leave this case open instead of resolving it/i
    end

    # A submitted determination cannot influence what is stored. The value is server-owned, so a
    # hand-built request naming another determination must not reach the record.
    test 'a forged determination cannot alter the stored determination' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'keep_separate', determination: 'fraud_or_security_review',
                     rationale: 'different people' }

      @review_case.reload
      assert_not_equal 'fraud_or_security_review', @review_case.resolution_determination
      assert @review_case.open?, 'a request carrying a stale determination must not resolve the case'
    end

    # Ignoring it outright would be worse than rejecting: an admin on a page rendered before this
    # shipped could choose "Needs more information", submit, and silently get a keep-separate
    # resolution -- the opposite of their intent.
    test 'a stale form carrying needs_more_information does not resolve the case' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'keep_separate', determination: 'needs_more_information',
                     rationale: 'still checking' }

      assert @review_case.reload.open?
      assert_nil @review_case.resolved_at
      assert_match(/out of date/i, flash[:alert])
    end

    test 'a resolution with no determination parameter records the server-owned value' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'keep_separate', rationale: 'different people' }

      @review_case.reload
      assert @review_case.resolved?
      assert_equal 'keep_separate', @review_case.resolution_determination
    end

    test 'show assigns unique control ids to every candidate merge form' do
      other_candidate = create(:constituent, email: "cand2-#{SecureRandom.hex(3)}@example.com")
      @review_case.duplicate_review_case_candidates.create!(
        candidate_user: other_candidate,
        match_reason: 'name_dob',
        snapshot: {}
      )

      get admin_duplicate_review_path(@review_case)

      forms = css_select('form[data-testid="duplicate-merge-form"]')
      assert_equal 2, forms.size
      control_ids = forms.flat_map { |form| form.css('input[id], select[id], textarea[id]').map { |control| control['id'] } }
      assert_equal control_ids.uniq.size, control_ids.size, 'per-candidate merge controls must not reuse DOM ids'
    end

    test 'show disables a non-email canonical choice when the other record owns the email-backed login' do
      @subject.update!(email: nil, communication_preference: :letter)

      get admin_duplicate_review_path(@review_case)

      prefix = "duplicate-review-#{@review_case.id}-candidate-#{@candidate.id}"
      assert_select "input[id='#{prefix}-canonical-#{@subject.id}'][disabled]"
      assert_select "input[id='#{prefix}-canonical-#{@candidate.id}']:not([disabled])"
      assert_select 'span', text: /Unavailable: the other record owns the email-backed login/
    end

    test 'show does not offer merge for an open case outside registration soft match' do
      support_case = open_case(
        create(:constituent, needs_duplicate_review: true),
        create(:constituent),
        source: :support_claim
      )

      get admin_duplicate_review_path(support_case)

      assert_response :success
      assert_select 'form[data-testid="duplicate-merge-form"]', count: 0
      assert_select 'p', text: /Same-person merge is available only for registration-match cases/
    end

    test 'show hides the forms and renders a read-only summary for a resolved case' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'approve', determination: 'keep_separate', rationale: 'not a match' }
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="resolution-summary"]'
      assert_no_match(/Merge these two records/, response.body)
      assert_no_match(/Resolve without merging/, response.body)
    end

    test 'resolve approves the case' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'approve', determination: 'keep_separate', rationale: 'not a match' }
      assert_redirected_to admin_duplicate_reviews_path
      assert_equal 'resolved_approved', @review_case.reload.status
      assert_not @subject.reload.needs_duplicate_review
    end

    test 'resolve surfaces failure without a rationale' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'approve', determination: 'keep_separate', rationale: '' }
      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert_equal 'open', @review_case.reload.status
    end

    test 'merge merges the pair and retires the duplicate' do
      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: { phone_user_id: @candidate.id, address_user_id: @candidate.id, phone_type: 'voice' },
        delivery_user_id: @candidate.id
      }
      assert_redirected_to admin_user_path(@candidate)
      assert @subject.reload.merged?
      assert_equal @candidate.id, @subject.merged_into_user_id
    end

    test 'merge ignores a forged application_ids param and still transfers every application the duplicate owns' do
      duplicate_app = create(:application, user: @subject)
      unrelated_owner = create(:constituent, email: "unrelated-#{SecureRandom.hex(3)}@example.com")
      unrelated_app = create(:application, user: unrelated_owner)

      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: { phone_user_id: @candidate.id, address_user_id: @candidate.id, phone_type: 'voice' },
        delivery_user_id: @candidate.id,
        # Forged/irrelevant application_ids: an unrelated app id plus a nonexistent id.
        # The service no longer accepts a transfer subset, so this must have no effect.
        application_ids: [unrelated_app.id, 0]
      }

      assert_redirected_to admin_user_path(@candidate)
      assert_equal @candidate.id, duplicate_app.reload.user_id, "the duplicate's own application must still transfer"
      assert_equal unrelated_owner.id, unrelated_app.reload.user_id, 'an unrelated application must never move'
    end

    test 'merge ignores a forged email source and keeps the canonical login authority' do
      canonical_email = @candidate.email
      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: {
          email: 'duplicate',
          phone_user_id: @candidate.id,
          address_user_id: @candidate.id,
          phone_type: 'voice'
        },
        delivery_user_id: @candidate.id
      }
      assert_redirected_to admin_user_path(@candidate)
      assert_equal canonical_email, @candidate.reload.email
      assert_nil @subject.reload.email
    end

    test 'merge rejects a forged contact source outside the reviewed pair' do
      outsider = create(:constituent)
      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: { phone_user_id: outsider.id, address_user_id: @candidate.id, phone_type: 'voice' },
        delivery_user_id: @candidate.id
      }

      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert_not @candidate.reload.merged?
      assert_not @subject.reload.merged?
    end

    test 'merge rejects a forged pair that excludes the case subject' do
      other_candidate = create(:constituent, email: "cand2-#{SecureRandom.hex(3)}@example.com")
      @review_case.duplicate_review_case_candidates.create!(candidate_user: other_candidate, match_reason: 'name_dob', snapshot: {})

      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@candidate.id, other_candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'forged candidate-only pair',
        reason_codes: ['name_dob'],
        contact: { phone_user_id: @candidate.id, address_user_id: @candidate.id, phone_type: 'voice' },
        delivery_user_id: @candidate.id
      }
      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert_not @candidate.reload.merged?
      assert_not other_candidate.reload.merged?
    end

    test 'clear_flag clears a legacy flag with rationale' do
      legacy = create(:constituent, needs_duplicate_review: true)
      assert_difference 'Event.where(action: \'duplicate_review_flag_cleared\').count', 1 do
        post clear_flag_admin_duplicate_reviews_path, params: { user_id: legacy.id, rationale: 'reviewed manually' }
      end
      assert_redirected_to admin_duplicate_reviews_path
      assert_not legacy.reload.needs_duplicate_review
    end

    test 'clear_flag refuses to clear a flag while an open case exists' do
      post clear_flag_admin_duplicate_reviews_path, params: { user_id: @subject.id, rationale: 'trying to bypass the case' }
      assert_redirected_to admin_duplicate_reviews_path
      assert @subject.reload.needs_duplicate_review, 'flag must stay set while the case is open'
      assert @review_case.reload.open?
    end

    test 'requires admin' do
      sign_in_for_integration_test(create(:constituent))
      get admin_duplicate_reviews_path
      assert_redirected_to root_path
    end

    private

    def open_case(subject, candidate, source: :registration_soft_match)
      review_case = DuplicateReviewCase.create!(
        source: source,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: candidate, match_reason: 'name_dob', snapshot: {})
      review_case
    end
  end
end
