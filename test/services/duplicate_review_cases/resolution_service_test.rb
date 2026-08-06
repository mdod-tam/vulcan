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
      result = resolve(action: :keep_separate)

      assert result.success?
      assert_equal 'keep_separate', @review_case.reload.resolution_determination
    end

    # The audit record must agree with the stored case; a divergence would make the evidence trail
    # claim a decision that was never taken.
    test 'the resolution audit event records the same server-owned determination' do
      resolve(action: :keep_separate)

      event = Event.where(action: 'duplicate_review_case_resolved').order(:id).last
      assert_equal 'keep_separate', event.metadata['resolution_determination']
    end

    # There is no path from this service to same_person_confirmed. Recording "these are one
    # identity" without consolidating the records would release submission while knowingly keeping
    # the duplicate, so it belongs to Users::DuplicateMergeService, atomically with the merge.
    test 'this service cannot record same_person_confirmed' do
      assert_equal 'keep_separate', DuplicateReviewCases::ResolutionService::NON_MERGE_DETERMINATION
      assert_raises(ArgumentError) do
        ResolutionService.new(
          duplicate_review_case: @review_case, actor: @admin, action: :keep_separate,
          determination: 'same_person_confirmed', rationale: 'x'
        )
      end
    end

    test 'approve resolves the case and clears the review flag' do
      result = nil
      assert_changes -> { @subject.reload.needs_duplicate_review }, from: true, to: false do
        result = resolve(action: :approve)
      end

      assert result.success?
      @review_case.reload
      assert_equal 'resolved_approved', @review_case.status
      # Even the legacy `approve` action records the server-owned determination now; the action
      # still maps to its own status, which 5c-2 retires once external consumers are inventoried.
      assert_equal 'keep_separate', @review_case.resolution_determination
      assert_equal @admin, @review_case.resolved_by
      assert @review_case.resolved_at.present?
    end

    test 'ignore resolves the case as ignored' do
      result = resolve(action: :ignore)
      assert result.success?
      assert_equal 'resolved_ignored', @review_case.reload.status
    end

    test 'keep separate resolves without moving contact facts' do
      original_phone = @subject.phone
      result = resolve(action: :keep_separate)
      assert result.success?
      assert_equal 'resolved_ignored', @review_case.reload.status
      assert_equal 'keep_separate', @review_case.resolution_determination
      assert_equal original_phone, @subject.reload.phone
    end

    test 'requires a rationale' do
      result = resolve(action: :approve, rationale: '  ')
      assert result.failure?
      assert_equal 'open', @review_case.reload.status
    end

    test 'requires an admin actor' do
      result = ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: create(:constituent),
        action: :approve,
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
      result = resolve(action: :approve, reason_codes: ['name_dob', 'free text'])
      assert result.failure?
      assert_match(/unsupported reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'rejects more reason codes than the cap allows' do
      result = resolve(action: :approve,
                       reason_codes: Array.new(DuplicateReviewCase::MAX_REASON_CODES + 1) { |i| "code-#{i}" })
      assert result.failure?
      assert_match(/too many reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'accepts operator reason codes alongside detection match reasons' do
      result = resolve(action: :approve, reason_codes: %w[name_dob admin_reviewed])
      assert result.success?, result.message
      assert_equal %w[name_dob admin_reviewed], @review_case.reload.resolution_metadata['reason_codes']
    end

    test 'does not clear review flag when another open case remains' do
      open_case_for(@subject)
      resolve(action: :ignore)
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

      resolve(action: :keep_separate)

      assert @subject.reload.needs_duplicate_review,
             'an open case of any source keeps the subject on the admin flagged list'
      assert_not Application.identity_review_pending_for?(@subject),
                 'only an open registration_soft_match case gates submission, so the gate must release'
    end

    test 'emits a resolution audit event' do
      assert_difference 'Event.where(action: \'duplicate_review_case_resolved\').count', 1 do
        resolve(action: :approve)
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
        assert resolve(action: :keep_separate).success?
        assert resolve(action: :keep_separate, review_case: second_case).success?
      end

      logged_case_ids = Event.where(action: 'duplicate_review_case_resolved')
                             .map { |event| event.metadata['duplicate_review_case_id'] }
      assert_equal [@review_case.id, second_case.id].sort, logged_case_ids.sort,
                   'each resolution must be attributable to the case it closed'
    end

    private

    def resolve(action:, rationale: 'reviewed and resolved', reason_codes: %w[name_dob], review_case: @review_case)
      ResolutionService.new(
        duplicate_review_case: review_case,
        actor: @admin,
        action: action,
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
  end
end
