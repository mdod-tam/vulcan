# frozen_string_literal: true

require 'test_helper'

module Admin
  class DuplicateReviewsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: "admin-dup-#{SecureRandom.hex(4)}@example.com")
      @subject = create(
        :constituent,
        first_name: 'Controller',
        last_name: 'Subject',
        needs_duplicate_review: true
      )
      @candidate = create(
        :constituent,
        first_name: 'Controller',
        last_name: 'Candidate',
        email: "cand-#{SecureRandom.hex(3)}@example.com"
      )
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
      assert_select "[data-testid='duplicate-review-case-row'][data-case-id='#{@review_case.id}']", count: 1 do
        assert_select 'h3', text: "Duplicate review case ##{@review_case.id}"
        assert_select '[data-testid="open-case-summary"]', text: '2 records in this case'
        assert_select '[data-testid="case-source"]', text: 'Found during registration'
        assert_select 'span', text: 'Name and date of birth match'
        assert_select '[data-testid="open-case-participant"]', count: 2
        assert_select "[data-testid='open-case-participant'][data-constituent-id='#{@subject.id}']", text: /#{@subject.full_name}/
        assert_select "[data-testid='open-case-participant'][data-constituent-id='#{@candidate.id}']", text: /#{@candidate.full_name}/
        assert_select 'a', text: 'Continue review', count: 1
      end
      assert_select '#open-cases-heading', text: 'Reviews in progress'
      assert_select '#legacy-heading', text: 'Other records flagged for review'
    end

    test 'index renders distinct pair cases sharing a subject without ambiguous duplicate rows' do
      second_candidate = create(:constituent, first_name: 'Controller', last_name: 'Second candidate')
      second_case = open_case(@subject, second_candidate)

      get admin_duplicate_reviews_path

      assert_select '[data-testid="duplicate-review-case-row"]', count: 2
      {
        @review_case => @candidate,
        second_case => second_candidate
      }.each do |review_case, candidate|
        assert_select "[data-testid='duplicate-review-case-row'][data-case-id='#{review_case.id}']", count: 1 do
          assert_select '[data-testid="open-case-participant"]', count: 2
          assert_select "[data-constituent-id='#{@subject.id}']", count: 1
          assert_select "[data-constituent-id='#{candidate.id}']", count: 1
        end
      end
    end

    test 'index preloads every user rendered in an open case' do
      get admin_duplicate_reviews_path

      review_case = assigns(:open_cases).detect { |candidate| candidate.id == @review_case.id }
      candidate_row = review_case.duplicate_review_case_candidates.first

      assert_predicate review_case.association(:subject_user), :loaded?
      assert_predicate review_case.association(:duplicate_review_case_candidates), :loaded?
      assert_predicate candidate_row.association(:candidate_user), :loaded?
    end

    test 'index presents a two-record match group with bounded facts and one exact pair action' do
      first = create(
        :constituent,
        first_name: 'Imported',
        last_name: 'Pair',
        date_of_birth: Date.new(1980, 2, 3),
        email: 'imported-pair-first@example.com',
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      )
      second = create(
        :constituent,
        first_name: 'IMPORTED',
        last_name: 'PAIR',
        date_of_birth: Date.new(1980, 2, 3),
        email: 'imported-pair-second@example.com',
        phone: '410-555-0101',
        needs_duplicate_review: false
      )

      get admin_duplicate_reviews_path

      assert_response :success
      assert_select '#unreviewed-groups-heading', text: 'Potential duplicate groups'
      assert_select '[data-testid="unreviewed-match-group"]', text: /Imported Pair/i, count: 1 do
        assert_select '[data-testid="match-group-summary"]', text: '2 records · 1 comparison remaining'
        assert_select '[data-testid="match-group-member"]', count: 2
        assert_select "a[href='#{admin_user_path(first)}']", text: first.full_name
        assert_select "a[href='#{admin_user_path(second)}']", text: second.full_name
        assert_select '[data-testid="unreviewed-pair-action"]', count: 1
        assert_select "form[action='#{review_pair_admin_duplicate_reviews_path}']", count: 1
        assert_select "input[type=submit][value='Compare these two records'][aria-label='Compare these two records: constituent records #{first.id} and #{second.id}']", count: 1
      end
      assert_includes response.body, 'Email present:'
      assert_includes response.body, 'Phone present:'
      assert_not_includes response.body, 'Review flag:'
      assert_not_includes response.body, 'imported-pair-first@example.com'
      assert_not_includes response.body, 'imported-pair-second@example.com'
      assert_not_includes response.body, '410-555-0101'
      assert_not_includes response.body, '1980-02-03'
    end

    test 'review_pair creates a case and redirects to its detail' do
      first, second = create_review_pair

      assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
        post review_pair_admin_duplicate_reviews_path,
             params: { first_user_id: second.id, second_user_id: first.id }
      end

      review_case = DuplicateReviewCase.where(source: :post_import_reconciliation).order(:id).last
      assert_redirected_to admin_duplicate_review_path(review_case)
    end

    test 'review_pair refuses a forged unrelated record without side effects' do
      first, = create_review_pair
      outsider = create(:constituent, first_name: 'Unrelated', last_name: 'Record')

      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        post review_pair_admin_duplicate_reviews_path,
             params: { first_user_id: first.id, second_user_id: outsider.id }
      end

      assert_redirected_to admin_duplicate_reviews_path
      assert_match(/no longer form a current supported/i, flash[:alert])
    end

    test 'review_pair requires admin authorization' do
      first, second = create_review_pair
      sign_in_for_integration_test(create(:constituent))

      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'] do
        post review_pair_admin_duplicate_reviews_path,
             params: { first_user_id: first.id, second_user_id: second.id }
      end

      assert_redirected_to root_path
    end

    test 'show renders grouped comparison and forms' do
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select 'h2#subject-heading', count: 0
      assert_select 'h2#candidates-heading', text: 'Record comparison'
      assert_select '[data-testid="candidate-comparison"]'
      assert_select '[data-testid="candidate-comparison"] [data-testid="record-facts"]', count: 2
      assert_select 'span', text: 'Name and date of birth match'
      assert_select 'form[data-controller~="final-submit-gate"][data-testid="duplicate-merge-form"]'
      assert_select 'input[name="contact[email]"]', count: 0
      assert_select 'input[name="contact[phone_type_agreed]"][value="1"]', count: 1
      assert_select 'select[name="contact[phone_type]"]', count: 0
      assert_select '[data-testid="shared-merge-fact"][data-fact="phone_type"]', text: /Voice.*Both records agree/m
      assert_select 'input[type="checkbox"][name="reason_codes[]"]', count: 0
      assert_select '[data-testid="case-match-evidence"]', text: /Name and date of birth match/
      assert_select 'label', text: 'Why these records are the same person (required)'
      assert_select 'input[type="submit"][data-final-submit-gate-target="submitButton"]:not([disabled])'
    end

    test 'show compares record age, login recency, and applications with neutral constituent labels' do
      date_of_birth = Date.new(1985, 4, 12)
      @subject.update_columns(created_at: 2.years.ago, last_sign_in_at: 3.days.ago, date_of_birth:)
      @candidate.update_columns(created_at: 1.year.ago, last_sign_in_at: 1.day.ago, date_of_birth:)
      create(:application, :approved, user: @candidate)

      get admin_duplicate_review_path(@review_case)

      assert_response :success
      assert_predicate assigns(:subject).association(:applications), :loaded?
      candidate_user = assigns(:candidates).first.candidate_user
      assert_predicate candidate_user.association(:applications), :loaded?
      assert_select 'h2#subject-heading', count: 0
      assert_select '[data-testid="candidate-comparison"]' do
        assert_select '[data-testid="record-date-of-birth"]', text: '04/12/1985', count: 2
        assert_select '[data-testid="record-created-at"]', count: 2
        assert_select '[data-testid="record-last-sign-in-at"]', count: 2
        assert_select '[data-testid="record-comparison-badges"] span', text: 'Newer record', count: 1
        assert_select '[data-testid="record-comparison-badges"] span', text: 'Most recent login', count: 1
        assert_select '[data-testid="record-comparison-badges"] span', text: 'No applications', count: 1
        assert_select '[data-testid="record-comparison-badges"] span', text: '1 application', count: 1
        assert_select 'legend', text: 'Canonical record and login identity'
        assert_select '[data-testid="shared-merge-facts"]' do
          assert_select '[data-testid="shared-merge-fact"][data-fact="date_of_birth"]', text: %r{04/12/1985.*Both records agree}m
          assert_select '[data-testid="shared-merge-fact"][data-fact="phone_type"]', text: /Voice.*Both records agree/m
          assert_select '[data-testid="shared-merge-fact"][data-fact="delivery"]', text: /Email.*Both records agree/m
        end
        assert_select '[data-testid="canonical-record-choice"]', count: 2
        assert_select '[data-testid="canonical-record-badges"] span', text: 'Newer record', count: 1
        assert_select '[data-testid="canonical-record-badges"] span', text: 'Most recent login', count: 1
        assert_select '[data-testid="canonical-record-choice"] dt', text: 'Last successful login:', count: 2
      end
      assert_select "label[for$='-canonical-#{@subject.id}'] span.font-medium",
                    text: "#{@subject.full_name} (Constituent ID #{@subject.id})"
      assert_select "label[for$='-canonical-#{@candidate.id}'] span.font-medium",
                    text: "#{@candidate.full_name} (Constituent ID #{@candidate.id})"
      assert_no_match(/\((?:subject|candidate) #\d+\)/i, response.body)
    end

    test 'show batches related users and applications without preloading nested relationship users' do
      dependent = create(:constituent, first_name: 'Related', last_name: 'Dependent')
      relationship = create(
        :guardian_relationship,
        guardian_user: @subject,
        dependent_user: dependent,
        relationship_type: 'Parent'
      )
      application = create(:application, :approved, user: dependent, managing_guardian: @subject)

      get admin_duplicate_review_path(@review_case)

      assert_response :success
      subject_relationship = assigns(:subject).guardian_relationships_as_guardian.find { |row| row.id == relationship.id }
      assert_not_predicate subject_relationship.association(:dependent_user), :loaded?

      related_user = assigns(:relationship_users_by_id).fetch(dependent.id)
      assert_predicate related_user.association(:applications), :loaded?
      assert_select '[data-testid="merge-relationship-impact"]' do
        assert_select 'span', text: /#{Regexp.escape(dependent.full_name)}/
        assert_select "a[href='#{admin_application_path(application)}']", text: "##{application.id} Approved"
      end
    end

    test 'show collapses every equal merge fact and submits locked agreement markers' do
      date_of_birth = Date.new(1985, 4, 12)
      @subject.update!(date_of_birth:, phone: nil, phone_type: nil)
      @candidate.update!(date_of_birth:, phone: nil, phone_type: nil)

      get admin_duplicate_review_path(@review_case)

      assert_response :success
      assert_select '[data-testid="shared-merge-fact"]', count: 4
      assert_select 'input[name="contact[phone_agreed]"][value="1"]', count: 1
      assert_select 'input[name="contact[address_agreed]"][value="1"]', count: 1
      assert_select 'input[name="delivery_agreed"][value="1"]', count: 1
      assert_select 'input[type="radio"][name="contact[phone_user_id]"]', count: 0
      assert_select 'input[type="radio"][name="contact[address_user_id]"]', count: 0
      assert_select 'input[type="radio"][name="delivery_user_id"]', count: 0
    end

    test 'merge accepts current agreement markers from collapsed rows' do
      @subject.update!(phone: nil, phone_type: nil)
      @candidate.update!(phone: nil, phone_type: nil)

      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['name_dob'],
        contact: { phone_agreed: '1', address_agreed: '1' },
        delivery_agreed: '1'
      }

      assert_redirected_to admin_user_path(@candidate)
      assert @subject.reload.merged?
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
      assert_select '#identity-outcome', text: /If they are the same person, merge them instead/i
      assert_select '#identity-outcome', text: /leave this case open/i
      assert_select 'form[action$="/resolve"]' do
        assert_select '[data-testid="case-match-evidence"]', count: 0
        assert_select 'input[name="reason_codes[]"]', count: 0
        assert_select 'label', text: 'Why these records are different people (required)'
      end
    end

    # A submitted determination cannot influence what is stored. The value is server-owned, so a
    # hand-built request naming another determination must not reach the record.
    test 'a forged determination cannot alter the stored determination' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { determination: 'fraud_or_security_review',
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
           params: { determination: 'needs_more_information',
                     rationale: 'still checking' }

      assert @review_case.reload.open?
      assert_nil @review_case.resolved_at
      assert_match(/out of date/i, flash[:alert])
    end

    test 'a resolution with no determination parameter records the server-owned value' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { rationale: 'different people' }

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
      assert_select 'p', text: /Unavailable: the other record owns the email-backed login/
    end

    test 'show does not offer merge for an open case outside the merge-eligible sources' do
      support_case = open_case(
        create(:constituent, needs_duplicate_review: true),
        create(:constituent),
        source: :support_claim
      )

      get admin_duplicate_review_path(support_case)

      assert_response :success
      assert_select 'form[data-testid="duplicate-merge-form"]', count: 0
      assert_select 'p', text: /Same-person merge is unavailable for this case source/
    end

    test 'show hides the forms and renders a read-only summary for a resolved case' do
      post resolve_admin_duplicate_review_path(@review_case), params: { rationale: 'not a match' }
      get admin_duplicate_review_path(@review_case)
      assert_response :success
      assert_select '[data-testid="resolution-summary"]'
      assert_no_match(/Merge these two records/, response.body)
      assert_no_match(/Resolve without merging/, response.body)
    end

    test 'resolve records server-owned status and evidence while clearing the flag' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { rationale: 'not a match', reason_codes: ['exact_phone'] }
      assert_redirected_to admin_duplicate_reviews_path
      assert_equal 'resolved_ignored', @review_case.reload.status
      assert_equal 'keep_separate', @review_case.resolution_determination
      assert_equal ['admin_reviewed'], @review_case.resolution_metadata['reason_codes']
      assert_not @subject.reload.needs_duplicate_review
    end

    # The action is server-owned, so a hand-built or cached request naming a retired one must be
    # refused rather than quietly resolved as keep-separate: the admin asked for an outcome the
    # server no longer offers, on a decision that releases a submission gate.
    test 'a stale form carrying a retired resolution_action does not resolve the case' do
      %w[approve ignore].each do |retired_action|
        post resolve_admin_duplicate_review_path(@review_case),
             params: { resolution_action: retired_action, rationale: 'not a match' }

        assert @review_case.reload.open?, "#{retired_action} must not resolve the case"
        assert_nil @review_case.resolved_at
        assert_match(/out of date/i, flash[:alert])
      end
    end

    # The other half of the rollover contract. The guard must reject only *conflicting* values, so a
    # page rendered between the two changes -- carrying the values the server would choose anyway --
    # still resolves normally. A guard that refused these would strand every admin holding an
    # intermediate form until they reloaded.
    test 'a compatible stale form still resolves the case' do
      post resolve_admin_duplicate_review_path(@review_case),
           params: { resolution_action: 'keep_separate', determination: 'keep_separate',
                     rationale: 'different people' }

      assert_redirected_to admin_duplicate_reviews_path
      @review_case.reload
      assert @review_case.resolved?
      assert_equal 'resolved_ignored', @review_case.status
      assert_equal 'keep_separate', @review_case.resolution_determination
    end

    # The status label and the determination are shown side by side on the resolution summary, so a
    # label that contradicts the determination misreports the decision staff recorded.
    test 'a resolved case reports the outcome without contradicting the determination' do
      post resolve_admin_duplicate_review_path(@review_case), params: { rationale: 'different people' }
      get admin_duplicate_review_path(@review_case)

      assert_response :success
      assert_select '[data-testid="resolution-summary"]' do
        assert_select 'dd', text: 'Resolved without merge'
        assert_select 'dd', text: 'Keep separate'
        assert_select 'dd', text: 'Ignored', count: 0
      end
    end

    # Nothing writes resolved_approved any more, but rows that already carry it must keep rendering
    # their own label rather than being retitled after the fact.
    test 'a historical resolved_approved case still displays Approved' do
      @review_case.update!(
        status: :resolved_approved,
        resolution_determination: :keep_separate,
        resolution_rationale: 'resolved under the retired approve action',
        resolved_by: @admin,
        resolved_at: Time.current
      )

      get admin_duplicate_review_path(@review_case)

      assert_response :success
      assert_select '[data-testid="resolution-summary"] dd', text: 'Approved'
    end

    test 'resolve surfaces failure without a rationale' do
      post resolve_admin_duplicate_review_path(@review_case), params: { rationale: '' }
      assert_redirected_to admin_duplicate_review_path(@review_case)
      assert_equal 'open', @review_case.reload.status
    end

    test 'merge merges the pair and retires the duplicate' do
      post merge_admin_duplicate_review_path(@review_case), params: {
        pair_ids: [@subject.id, @candidate.id],
        canonical_user_id: @candidate.id,
        same_person_confirmed: '1',
        rationale: 'same person confirmed',
        reason_codes: ['manual_review'],
        contact: { phone_user_id: @candidate.id, address_user_id: @candidate.id, phone_type: 'voice' },
        delivery_user_id: @candidate.id
      }
      assert_redirected_to admin_user_path(@candidate)
      assert @subject.reload.merged?
      assert_equal @candidate.id, @subject.merged_into_user_id
      assert_equal ['name_dob'], @review_case.reload.resolution_metadata['reason_codes']
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
      legacy = create(
        :constituent,
        first_name: 'UniqueLegacy',
        last_name: SecureRandom.hex(6),
        date_of_birth: Date.new(1971, 1, 2),
        needs_duplicate_review: true
      )
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

    def create_review_pair
      date_of_birth = Date.new(1986, 6, 17)
      [
        create(:constituent, first_name: 'Controller', last_name: 'Pair', date_of_birth: date_of_birth,
                             email: "controller-pair-a-#{SecureRandom.hex(4)}@example.com"),
        create(:constituent, first_name: 'controller', last_name: 'pair', date_of_birth: date_of_birth,
                             email: "controller-pair-b-#{SecureRandom.hex(4)}@example.com")
      ]
    end

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
