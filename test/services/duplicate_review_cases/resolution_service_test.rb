# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ResolutionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: true)
      @review_case = open_case_for(@subject)
    end

    # The determination is server-owned. A non-merge resolution means exactly one thing, so there is
    # no input that could record anything else -- the five-value control is gone, and the service
    # takes no determination parameter at all.
    test 'a non-merge resolution always records keep_separate' do
      result = resolve

      assert result.success?
      assert_equal 'keep_separate', @review_case.reload.resolution_determination
    end

    # The audit record must agree with the stored case; a divergence would make the evidence trail
    # claim a decision that was never taken.
    test 'the resolution audit event records the same server-owned determination' do
      resolve

      event = Event.where(action: 'duplicate_review_case_resolved').order(:id).last
      assert_equal 'keep_separate', event.metadata['resolution_determination']
    end

    # `resolution_action` is no longer written. The consumer inventory found no reader anywhere, so
    # 5c-2 stops emitting it rather than deriving a replacement value nobody consumes. Historical
    # events keep whatever they recorded.
    test 'the resolution audit event no longer carries resolution_action' do
      resolve

      event = Event.where(action: 'duplicate_review_case_resolved').order(:id).last
      assert_not event.metadata.key?('resolution_action')
    end

    # There is no path from this service to same_person_confirmed. Recording "these are one
    # identity" without consolidating the records would release submission while knowingly keeping
    # the duplicate, so it belongs to Users::DuplicateMergeService, atomically with the merge.
    test 'this service cannot record same_person_confirmed' do
      assert_equal 'keep_separate', DuplicateReviewCases::ResolutionService::NON_MERGE_DETERMINATION
      assert_raises(ArgumentError) do
        ResolutionService.new(
          duplicate_review_case: @review_case, actor: @admin,
          determination: 'same_person_confirmed', rationale: 'x'
        )
      end
    end

    # The status is server-owned alongside the determination: every non-merge resolution records
    # `resolved_ignored`, so there is no input that could steer it elsewhere.
    test 'a resolution records the server-owned status and clears the review flag' do
      original_phone = @subject.phone
      result = nil
      assert_changes -> { @subject.reload.needs_duplicate_review }, from: true, to: false do
        result = resolve
      end

      assert result.success?
      @review_case.reload
      assert_equal 'resolved_ignored', @review_case.status
      assert_equal 'keep_separate', @review_case.resolution_determination
      assert_equal @admin, @review_case.resolved_by
      assert @review_case.resolved_at.present?
      assert_equal original_phone, @subject.reload.phone,
                   'a non-merge resolution moves no contact facts'
    end

    # `resolved_approved` stays mapped on the model so historical rows keep rendering, but nothing
    # writes it any more.
    test 'nothing records resolved_approved' do
      assert_equal :resolved_ignored, ResolutionService::NON_MERGE_STATUS
      resolve
      assert_equal 'resolved_ignored', @review_case.reload.status
    end

    # The action is not an accepted input, so a stale caller cannot select a retired outcome and
    # have it quietly honoured.
    test 'this service takes no action parameter' do
      assert_raises(ArgumentError) do
        ResolutionService.new(
          duplicate_review_case: @review_case, actor: @admin,
          action: :approve, rationale: 'x'
        )
      end
    end

    test 'requires a rationale' do
      result = resolve(rationale: '  ')
      assert result.failure?
      assert_equal 'open', @review_case.reload.status
    end

    test 'requires an admin actor' do
      result = ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: create(:constituent),
        rationale: 'looks fine'
      ).call
      assert result.failure?
      assert_equal 'open', @review_case.reload.status
    end

    # Reason codes land in immutable resolution metadata and audit evidence, so they are checked
    # against a server-owned vocabulary. Validating in preflight (not only at the model) matters
    # here: resolve_case! writes with update!, and #call rescues StaleCaseError only, so a
    # model-level rejection would surface as an unhandled RecordInvalid rather than a failure.
    test 'rejects a reason code outside the server-owned vocabulary' do
      result = resolve(reason_codes: ['name_dob', 'free text'])
      assert result.failure?
      assert_match(/unsupported reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'rejects more reason codes than the cap allows' do
      result = resolve(reason_codes: Array.new(DuplicateReviewCase::MAX_REASON_CODES + 1) { |i| "code-#{i}" })
      assert result.failure?
      assert_match(/too many reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'accepts operator reason codes alongside detection match reasons' do
      result = resolve(reason_codes: %w[name_dob admin_reviewed])
      assert result.success?, result.message
      assert_equal %w[name_dob admin_reviewed], @review_case.reload.resolution_metadata['reason_codes']
    end

    test 'does not clear review flag when another open case remains' do
      open_case_for(@subject)
      resolve
      assert @subject.reload.needs_duplicate_review
    end

    # The review flag and the submission gate are recomputed from different sets and are not
    # synonyms: the flag counts open cases of *any* source, while the gate counts only open
    # `registration_soft_match` cases. Each half is covered elsewhere -- the flag above, the gate's
    # source filter in ApplicationCreatorTest -- but only together do they pin the divergence, which
    # is the state the resolving admin actually leaves behind. Documentation asserted the opposite
    # (that a remaining case holds both) through PR198, so this asserts both in one sequence.
    test 'resolving the last registration case releases the submission gate while another source keeps the flag' do
      open_case_for(@subject, source: :paper_intake)

      resolve

      assert @subject.reload.needs_duplicate_review,
             'an open case of any source keeps the subject on the admin flagged list'
      assert_not Application.identity_review_pending_for?(@subject),
                 'only an open registration_soft_match case gates submission, so the gate must release'
    end

    test 'emits a resolution audit event' do
      assert_difference 'Event.where(action: \'duplicate_review_case_resolved\').count', 1 do
        resolve
      end
    end

    # A subject can hold several open cases at once, so an admin can resolve two of them inside
    # AuditEventService::DEDUP_WINDOW. The fingerprint must carry the case id: without it both
    # events collapse to the bare action name for the same auditable and the second resolution
    # loses its audit event. Deliberately not time-travelled -- the point is that the real window
    # is in force.
    test 'resolving two cases for the same subject records an audit event for each' do
      second_case = open_case_for(@subject)

      assert_difference 'Event.where(action: \'duplicate_review_case_resolved\').count', 2 do
        assert resolve.success?
        assert resolve(review_case: second_case).success?
      end

      logged_case_ids = Event.where(action: 'duplicate_review_case_resolved')
                             .map { |event| event.metadata['duplicate_review_case_id'] }
      assert_equal [@review_case.id, second_case.id].sort, logged_case_ids.sort,
                   'each resolution must be attributable to the case it closed'
    end

    test 'post-import different-person resolution clears both pair flags and remains suppressed on synchronization' do
      first, second = matching_constituents(2, needs_duplicate_review: true)
      review_case = open_reconciliation_case(first, second)

      result = resolve(review_case: review_case, reason_codes: %w[name_dob admin_reviewed])

      assert result.success?, result.message
      assert_equal 'keep_separate', review_case.reload.resolution_determination
      assert_not first.reload.needs_duplicate_review
      assert_not second.reload.needs_duplicate_review
      assert_not Application.identity_review_pending_for?(first)
      assert_not Application.identity_review_pending_for?(second)

      assert_no_changes -> { [first.reload.needs_duplicate_review?, second.reload.needs_duplicate_review?] } do
        DuplicateReconciliation::ReviewFlagSyncService.new(user_ids: [first.id, second.id]).call
      end
      assert_equal :confirmed_different,
                   DuplicateReconciliation::Population.new.pair_for_ids(first.id, second.id).state
    end

    test 'post-import resolution preserves flags when either participant still has an unresolved pair' do
      first, second, third = matching_constituents(3, needs_duplicate_review: true)
      review_case = open_reconciliation_case(first, second)

      result = resolve(review_case: review_case)

      assert result.success?, result.message
      assert first.reload.needs_duplicate_review, 'first still participates in the first-third pair'
      assert second.reload.needs_duplicate_review, 'second still participates in the second-third pair'
      assert DuplicateReconciliation::Population.new.pair_for_ids(first.id, third.id).unresolved?
      assert DuplicateReconciliation::Population.new.pair_for_ids(second.id, third.id).unresolved?
    end

    test 'post-import resolution fails closed when the locked records no longer match' do
      first, second = matching_constituents(2, needs_duplicate_review: true)
      review_case = open_reconciliation_case(first, second)
      second.update!(last_name: 'Changed after review entry')

      assert_no_difference 'Event.where(action: \'duplicate_review_case_resolved\').count' do
        result = resolve(review_case: review_case)

        assert result.failure?
        assert_match(/no longer form a supported/i, result.message)
      end
      assert review_case.reload.open?
      assert first.reload.needs_duplicate_review
      assert second.reload.needs_duplicate_review
    end

    test 'post-import resolution rejects a case that is not exactly pair scoped' do
      first, second, third = matching_constituents(3, needs_duplicate_review: true)
      review_case = open_reconciliation_case(first, second)
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: third,
        match_reason: 'name_dob',
        snapshot: {}
      )

      result = resolve(review_case: review_case)

      assert result.failure?
      assert_match(/exactly one canonical pair/i, result.message)
      assert review_case.reload.open?
    end

    private

    def resolve(rationale: 'reviewed and resolved', reason_codes: %w[name_dob], review_case: @review_case)
      ResolutionService.new(
        duplicate_review_case: review_case,
        actor: @admin,
        rationale: rationale,
        reason_codes: reason_codes
      ).call
    end

    def open_case_for(user, source: :registration_soft_match)
      DuplicateReviewCase.create!(
        source: source,
        subject_user: user,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
    end

    def matching_constituents(count, needs_duplicate_review:)
      users = Array.new(count) do
        create(
          :constituent,
          first_name: 'Resolution',
          last_name: "Pair#{SecureRandom.hex(4)}",
          date_of_birth: Date.new(1988, 2, 14),
          email: "resolution-#{SecureRandom.hex(5)}@example.com",
          needs_duplicate_review: needs_duplicate_review
        )
      end
      shared_last_name = users.first.last_name
      users.drop(1).each { |user| user.update!(last_name: shared_last_name) }
      users
    end

    def open_reconciliation_case(first, second)
      subject, candidate = [first, second].sort_by(&:id)
      result = DuplicateReviewCases::CreateService.new(
        source: :post_import_reconciliation,
        subject_user: subject,
        actor: @admin,
        reason_codes: ['name_dob'],
        candidates: [DuplicateReviewCases::CreateService::CandidateInput.new(candidate, 'name_dob', {})]
      ).call
      assert result.success?, result.message
      result.data.fetch(:duplicate_review_case)
    end
  end
end
