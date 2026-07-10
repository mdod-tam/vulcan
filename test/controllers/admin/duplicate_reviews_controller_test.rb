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
    end

    test 'show renders grouped comparison and forms' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="candidate-comparison"]'
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
        contact: { email: 'canonical', phone: 'canonical', address: 'canonical', phone_type: 'voice' },
        delivery_choice: 'canonical'
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
        contact: { email: 'canonical', phone: 'canonical', address: 'canonical', phone_type: 'voice' },
        delivery_choice: 'canonical',
        # Forged/irrelevant application_ids: an unrelated app id plus a nonexistent id.
        # The service no longer accepts a transfer subset, so this must have no effect.
        application_ids: [unrelated_app.id, 0]
      }

      assert_redirected_to admin_user_path(@candidate)
      assert_equal @candidate.id, duplicate_app.reload.user_id, "the duplicate's own application must still transfer"
      assert_equal unrelated_owner.id, unrelated_app.reload.user_id, 'an unrelated application must never move'
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
        contact: { email: 'canonical', phone: 'canonical', address: 'canonical', phone_type: 'voice' },
        delivery_choice: 'canonical'
      }
      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert_not @candidate.reload.merged?
      assert_not other_candidate.reload.merged?
    end

    test 'clear_flag clears a legacy flag with rationale' do
      legacy = create(:constituent, needs_duplicate_review: true)
      post clear_flag_admin_duplicate_reviews_path, params: { user_id: legacy.id, rationale: 'reviewed manually' }
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

    def open_case(subject, candidate)
      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
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
