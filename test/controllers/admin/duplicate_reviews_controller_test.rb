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

    test 'index lists every active workflow state with labels and legacy flags' do
      legacy = create(:constituent, needs_duplicate_review: true)
      awaiting = open_case(create(:constituent, needs_duplicate_review: true), create(:constituent))
      resolve_case(awaiting, 'needs_more_information')
      security = open_case(create(:constituent, needs_duplicate_review: true), create(:constituent))
      resolve_case(security, 'fraud_or_security_review')

      get admin_duplicate_reviews_path

      assert_response :success
      {
        @review_case => 'Open',
        awaiting => 'Awaiting information',
        security => 'Security review'
      }.each do |review_case, label|
        assert_select "[data-testid='duplicate-review-case-row'][data-case-id='#{review_case.id}']" do
          assert_select '[data-testid="case-workflow-state"]', text: label
        end
      end
      assert_match legacy.full_name, response.body
    end

    test 'index filters active cases by workflow state' do
      awaiting = open_case(create(:constituent, needs_duplicate_review: true), create(:constituent))
      resolve_case(awaiting, 'needs_more_information')

      get admin_duplicate_reviews_path(state: 'awaiting_information')

      assert_response :success
      assert_select "[data-testid='duplicate-review-case-row'][data-case-id='#{awaiting.id}']" do
        assert_select '[data-testid="case-workflow-state"]', text: 'Awaiting information'
      end
      assert_select "[data-testid='duplicate-review-case-row'][data-case-id='#{@review_case.id}']", count: 0
    end

    test 'show renders grouped comparison and forms' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="candidate-comparison"]'
      assert_select '[data-testid="record-comparison"]'
    end

    test 'show hides the forms and renders a read-only summary for a resolved case' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { outcome: 'keep_separate', rationale: 'not a match' }
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="resolution-summary"]'
      assert_no_match(/Merge these two records/, response.body)
      assert_no_match(/Record review outcome/, response.body)
    end

    test 'show makes merge unavailable in each nonterminal workflow state' do
      {
        'needs_more_information' => 'Awaiting information',
        'fraud_or_security_review' => 'Security review'
      }.each do |outcome, label|
        review_case = open_case(create(:constituent, needs_duplicate_review: true), create(:constituent))
        result = resolve_case(review_case, outcome)
        assert result.success?, result.message

        get admin_duplicate_review_path(review_case)

        assert_response :success
        assert_select '[data-testid="case-workflow-state"]', text: label
        assert_select '[data-testid="merge-unavailable"]'
        assert_select "form[action='#{merge_admin_duplicate_review_path(review_case)}']", count: 0
        assert_select "form[action='#{resume_admin_duplicate_review_path(review_case)}']"
        assert_no_match(/This case is resolved/, response.body)
      end
    end

    test 'resume returns a nonterminal case to normal review and preserves rationale on failure' do
      resolve_case(@review_case, 'needs_more_information')

      post resume_admin_duplicate_review_path(@review_case), params: { rationale: '' }
      assert_response :unprocessable_content
      assert @review_case.reload.awaiting_information?
      assert_select "form[action='#{resume_admin_duplicate_review_path(@review_case)}'] textarea", text: ''

      post resume_admin_duplicate_review_path(@review_case), params: { rationale: 'Requested records arrived.' }
      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert @review_case.reload.open?
      assert @subject.reload.needs_duplicate_review
    end

    test 'forged resume and merge transitions fail server side for nonterminal cases' do
      resolve_case(@review_case, 'fraud_or_security_review')

      post resolve_admin_duplicate_review_path(@review_case),
           params: { outcome: 'keep_separate', rationale: 'Forged terminal transition.' }
      assert_response :unprocessable_content
      assert @review_case.reload.security_review?

      post merge_admin_duplicate_review_path(@review_case), params: merge_params
      assert_response :unprocessable_content
      assert @review_case.reload.security_review?
      assert_not @subject.reload.merged?
      assert_not @candidate.reload.merged?
    end

    test 'resolve records one terminal review outcome' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { outcome: 'keep_separate', rationale: 'not a match' }
      assert_redirected_to admin_duplicate_reviews_path
      assert_equal 'resolved_keep_separate', @review_case.reload.status
      assert_not @subject.reload.needs_duplicate_review
    end

    test 'resolve surfaces failure without a rationale and preserves the submitted outcome' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { outcome: 'keep_separate', rationale: '' }
      assert_response :unprocessable_content
      assert_equal 'open', @review_case.reload.status
      assert_select 'input#resolve_outcome_keep_separate[checked]'
      assert_select '#resolve_rationale', text: ''
    end

    test 'authorized relationship failure preserves outcome and rationale' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { outcome: 'authorized_relationship_confirmed', rationale: 'Relationship confirmed by staff.' }

      assert_response :unprocessable_content
      assert_match(/must be created before resolution|create the supported guardian/i, response.body)
      assert_select 'input#resolve_outcome_authorized_relationship_confirmed[checked]'
      assert_select '#resolve_rationale', text: 'Relationship confirmed by staff.'
      assert @review_case.reload.open?
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
      assert_response :unprocessable_content
      assert_not @candidate.reload.merged?
      assert_not other_candidate.reload.merged?
    end

    test 'failed merge reopens the submitted candidate details and preserves the submitted choices' do
      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'confirmed same person via support call',
        reason_codes: ['name_dob'],
        # phone_type deliberately omitted: a real phone would require it, triggering failure.
        contact: { email: 'canonical', phone: 'duplicate', address: 'canonical' },
        delivery_choice: 'canonical'
      }
      assert_response :unprocessable_content
      assert_not @subject.reload.merged?

      dom_id_prefix = "merge_#{@candidate.id}"
      assert_select "details[open] ##{dom_id_prefix}_canonical_user_id_candidate[checked]"
      assert_select "##{dom_id_prefix}_contact_email_canonical[checked]"
      assert_select "##{dom_id_prefix}_contact_phone_duplicate[checked]"
      assert_select "##{dom_id_prefix}_delivery_choice_canonical[checked]"
      assert_select "##{dom_id_prefix}_rationale", text: 'confirmed same person via support call'
      assert_select "##{dom_id_prefix}_same_person_confirmed[checked]"
    end

    test 'each candidate merge form and the resolve form render unique element ids' do
      other_candidate = create(:constituent, email: "cand2-#{SecureRandom.hex(3)}@example.com")
      @review_case.duplicate_review_case_candidates.create!(candidate_user: other_candidate, match_reason: 'name_dob', snapshot: {})

      get admin_duplicate_review_path(@review_case)
      assert_response :success

      ids = response.body.scan(/\sid="([^"]+)"/).flatten
      duplicated = ids.tally.select { |_id, count| count > 1 }
      assert_empty duplicated, "expected no duplicate element ids, found: #{duplicated.keys.join(', ')}"
    end

    test 'shows the subject record standalone only when there is no comparable candidate' do
      unmergeable_case = open_case(@subject, nil)

      get admin_duplicate_review_path(unmergeable_case)
      assert_response :success
      assert_select '[data-testid="record-facts"]', count: 1
      assert_select '[data-testid="record-comparison"]', count: 0

      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="record-facts"]', count: 0
      assert_select '[data-testid="record-comparison"]', count: 1
    end

    test 'comparison table visibly flags a differing field and mutes an identical one' do
      # @subject and @candidate both come from the constituent factory with the same
      # default communication_preference, so that field should read as identical, while
      # email is deliberately different (set in setup) so it should be flagged.
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_select 'tr[data-diff="different"]' do
        assert_select 'td', text: /Email/
        assert_select 'span', text: 'Differs'
      end
      assert_select 'tr[data-diff="same"] td', text: /Notice preference/
    end

    test 'comparison table header shows each full name and an open-profile link' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_select '[data-testid="record-comparison"] table thead th' do
        assert_select 'a[href=?]', admin_user_path(@subject), text: 'Open profile'
        assert_select 'a[href=?]', admin_user_path(@candidate), text: 'Open profile'
      end
      assert_match(/#{Regexp.escape(@subject.full_name)}/, response.body)
      assert_match(/#{Regexp.escape(@candidate.full_name)}/, response.body)
    end

    test 'comparison table wraps in a horizontally scrollable container for narrow viewports' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_select '[data-testid="record-comparison"] .overflow-x-auto table'
    end

    test 'merge and resolve submit-gate status text is announced accessibly' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      dom_id_prefix = "merge_#{@candidate.id}"
      assert_select "##{dom_id_prefix}_submit_gate_status[aria-live='polite']"
      assert_select "#resolve_submit_gate_status[aria-live='polite']"
    end

    test 'comparison table warns when a record cannot be retired due to a blocker' do
      @subject.recovery_requests.create!(status: 'pending', ip_address: '127.0.0.1', user_agent: 'test')
      application = create(:application, user: @candidate)
      create(:secure_request_form, application: application, recipient: @candidate)

      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_match(/Subject ##{@subject.id} cannot be retired.*pending recovery request/, response.body)
      assert_match(/Candidate ##{@candidate.id} cannot be retired.*active secure form/, response.body)
      assert_no_match(/This (case|merge) is blocked/i, response.body)
    end

    test 'comparison table warns on MFA vs none and stays quiet once both sides match' do
      create(:webauthn_credential, user: @subject)

      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_match(%r{MFA/passkey methods differ}, response.body)

      create(:webauthn_credential, user: @candidate)
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_no_match(%r{MFA/passkey methods differ}, response.body)
    end

    test 'comparison table warns on a method mismatch even when both sides have some MFA' do
      create(:webauthn_credential, user: @subject)
      @candidate.sms_credentials.create!(phone_number: '410-555-9999', verified_at: Time.current)

      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_match(%r{MFA/passkey methods differ}, response.body)
    end

    test 'comparison table does not warn on a pure credential-count difference within the same method' do
      create(:webauthn_credential, user: @subject)
      create(:webauthn_credential, user: @subject)
      create(:webauthn_credential, user: @candidate)

      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_no_match(%r{MFA/passkey methods differ}, response.body)
    end

    test 'comparison table excludes unverified SMS setup rows from enrolled MFA methods' do
      @candidate.sms_credentials.create!(phone_number: '410-555-9999', verified_at: nil)

      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_no_match(%r{MFA/passkey methods differ}, response.body)
      assert_match(/SMS \(verified\): 0/, response.body)
      assert_match(/Pending SMS setup: 1/, response.body)
    end

    test 'comparison table counts only unexpired sessions as active' do
      @subject.sessions.create!(user_agent: 'active-test', ip_address: '127.0.0.1', expires_at: 1.hour.from_now)
      @subject.sessions.create!(user_agent: 'expired-test', ip_address: '127.0.0.1', expires_at: 1.hour.ago)

      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_match(/Active sessions: 1/, response.body)
      assert_no_match(/Active sessions: 2/, response.body)
    end

    test 'merge form submit button starts disabled and is wired to the submit gate' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      dom_id_prefix = "merge_#{@candidate.id}"
      assert_select "form[action='#{merge_admin_duplicate_review_path(@review_case)}']" \
                    "[data-controller='final-submit-gate']" do
        assert_select "input[type=submit][disabled][data-final-submit-gate-target='submitButton']"
      end
      assert_select "##{dom_id_prefix}_submit_gate_status[data-final-submit-gate-target='status']"
    end

    test 'merge form reason-codes fieldset requires at least one checked signal' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      assert_select "form[action='#{merge_admin_duplicate_review_path(@review_case)}'] " \
                    "fieldset[data-requires-one-checkbox='true']"
    end

    test 'merge form requires explicit admin evidence confirmation when no match signal was stored' do
      @review_case.update!(metadata: { 'reason_codes' => [] })

      get admin_duplicate_review_path(@review_case)
      assert_response :success

      merge_form_selector = "form[action='#{merge_admin_duplicate_review_path(@review_case)}']"
      assert_select "#{merge_form_selector} fieldset[data-requires-one-checkbox='true']" do
        assert_select 'legend', text: 'Merge evidence'
        assert_select 'p', text: /No structured match signal was stored/
        assert_select "input[name='reason_codes[]'][value='admin_reviewed'][checked]", count: 0
        assert_select 'span', text: /I reviewed the available records and found sufficient evidence to merge/
      end
    end

    test 'resolve form submit button starts disabled and is wired to the submit gate, without requiring a signal' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success

      resolve_form_selector = "form[action='#{resolve_admin_duplicate_review_path(@review_case)}']"
      assert_select "#{resolve_form_selector}[data-controller='final-submit-gate']" do
        assert_select "input[type=submit][disabled][data-final-submit-gate-target='submitButton']"
      end
      assert_select "#resolve_submit_gate_status[data-final-submit-gate-target='status']"
      assert_select "#{resolve_form_selector} fieldset[data-requires-one-checkbox]", count: 0
      assert_select "#{resolve_form_selector} fieldset" do
        assert_select 'legend', text: 'Review outcome'
        assert_select "input[name='outcome']", count: 4
        assert_select '#resolve_outcome_keep_separate'
        assert_select '#resolve_outcome_authorized_relationship_confirmed'
        assert_select '#resolve_outcome_needs_more_information'
        assert_select '#resolve_outcome_fraud_or_security_review'
      end
      assert_select "#{resolve_form_selector} [name='resolution_action']", count: 0
      assert_select "#{resolve_form_selector} [name='determination']", count: 0
    end

    test 'clear_flag clears a legacy flag with rationale' do
      legacy = create(:constituent, needs_duplicate_review: true)
      post clear_flag_admin_duplicate_reviews_path, params: { user_id: legacy.id, rationale: 'reviewed manually' }
      assert_redirected_to admin_duplicate_reviews_path
      assert_not legacy.reload.needs_duplicate_review
    end

    test 'clear_flag refuses to clear a flag while any pending case exists' do
      resolve_case(@review_case, 'needs_more_information')

      post clear_flag_admin_duplicate_reviews_path, params: { user_id: @subject.id, rationale: 'trying to bypass the case' }
      assert_redirected_to admin_duplicate_reviews_path
      assert @subject.reload.needs_duplicate_review, 'flag must stay set while the case is pending'
      assert @review_case.reload.awaiting_information?
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

    def resolve_case(review_case, outcome)
      result = DuplicateReviewCases::ResolutionService.new(
        duplicate_review_case: review_case,
        actor: @admin,
        outcome: outcome,
        rationale: 'Controller test review rationale.',
        reason_codes: ['name_dob']
      ).call
      assert result.success?, result.message
      result
    end

    def merge_params
      {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: { email: 'canonical', phone: 'canonical', address: 'canonical', phone_type: 'voice' },
        delivery_choice: 'canonical'
      }
    end
  end
end
