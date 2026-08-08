# frozen_string_literal: true

module DuplicateReviewCases
  # Resolves an open duplicate review case without moving any data. There is exactly one such
  # outcome: staff decided the records are different people. It records the admin actor, that fixed
  # determination, and a required rationale, then clears the subject review flag when no other open
  # case remains. Same-person merges are handled by Users::DuplicateMergeService.
  class ResolutionService < BaseService
    class StaleCaseError < StandardError; end

    # The status every non-merge resolution records, server-owned like the determination beside it.
    # There is one non-merge outcome, so there is one status; the durable semantics live in
    # `resolution_determination`, not in a separate staff-selected action.
    #
    # `resolved_approved` remains mapped on the model as a legacy **readable** status so existing
    # rows keep rendering, but nothing writes it. Do not remove that mapping: the schema's
    # `status = ANY (ARRAY[0, 1, 2, 3])` check constraint means unmapping the Rails key would load
    # those rows as `nil` rather than removing the state.
    NON_MERGE_STATUS = :resolved_ignored

    # The only determination this service may record, and it is server-owned rather than selected.
    #
    # Resolving a case is not a neutral bookkeeping act. It recomputes two *independent* effects
    # from the cases that remain open:
    #
    # - the PR5a submission gate is released when no open `registration_soft_match` case remains
    #   for the subject (the gate filters on that source);
    # - `needs_duplicate_review` is cleared when no open case of *any* source remains, which also
    #   removes the subject from the admin flagged list, the review-count badge, and the row/badge
    #   highlights.
    #
    # Neither is automatic on resolution, and they can diverge: a subject with another open case of
    # a different source keeps the flag while the gate releases. So only a *completed identity
    # decision* may close a case, and "these are different people" is the only such decision that
    # does not move data.
    #
    # The rest of the matrix is deliberately unreachable from here:
    #
    # - `same_person_confirmed` means two records are one identity. Closing without consolidating
    #   would release submission while knowingly keeping the duplicate, so it is reserved to
    #   Users::DuplicateMergeService and written atomically with the merge itself. If the merge
    #   cannot complete, the case stays open.
    # - `needs_more_information` and `fraud_or_security_review` are not decisions at all. The
    #   duplicate-review queue is the only durable queue that exists; closing either would remove
    #   the work item *and* its staff visibility at the moment the risk materializes.
    # - `authorized_relationship_confirmed` needs server-verifiable evidence, and there is nowhere
    #   to verify it against yet: this service receives no selected candidate, and
    #   `guardian_relationships` has no active/revoked state.
    #
    # This is an allowlist of one, not a denylist. A denylist fails open for anything not yet
    # listed, which is how a determination nobody had triaged could terminate a case.
    NON_MERGE_DETERMINATION = 'keep_separate'

    # Neither `determination` nor `action` is a parameter: a non-merge resolution has exactly one
    # outcome and one status, so the server owns both rather than accepting them as input. A
    # submitted value is not silently ignored either -- Admin::DuplicateReviewsController rejects a
    # conflicting `determination` or `resolution_action` before calling this service, so a stale
    # page cannot resolve a case under an intent the server would otherwise reinterpret.
    def initialize(duplicate_review_case:, actor:, rationale:, reason_codes: [])
      super()
      @duplicate_review_case = duplicate_review_case
      @actor = actor
      @rationale = rationale.to_s.strip
      @reason_codes = Array(reason_codes).map(&:to_s).compact_blank.uniq
    end

    def call
      validation_error = preflight
      return failure(validation_error) if validation_error

      ActiveRecord::Base.transaction do
        # User rows lock before the case, matching Users::DuplicateMergeService's order, so
        # a resolution and a same-person merge racing on the same case/subject can never
        # deadlock (Postgres would otherwise detect a User<->Case ABBA cycle and abort one
        # transaction, surfacing as an unhandled error instead of a clean failure result).
        lock_user_participants!
        @duplicate_review_case.lock!
        raise StaleCaseError, 'Case is no longer open' unless @duplicate_review_case.open?

        resolve_case!
        sync_subject_review_flag!
        log_resolution!
      end

      success('Duplicate review case resolved', { duplicate_review_case: @duplicate_review_case })
    rescue StaleCaseError => e
      failure(e.message)
    end

    private

    def preflight
      return 'Duplicate review case is required' if @duplicate_review_case.blank?
      return 'Case is not open' unless @duplicate_review_case.open?
      return 'An admin actor is required' unless admin_actor?
      return 'A rationale is required' if @rationale.blank?

      reason_code_error
    end

    # Reason codes become immutable resolution metadata and audit evidence, so they are checked
    # against the server-owned vocabulary here rather than only at the model: resolve_case! uses
    # update!, and #call rescues StaleCaseError only, so a model-level rejection would surface as
    # an unhandled RecordInvalid instead of a failure result the admin can act on.
    def reason_code_error
      return "Too many reason/evidence codes (maximum #{DuplicateReviewCase::MAX_REASON_CODES})" if
        @reason_codes.length > DuplicateReviewCase::MAX_REASON_CODES

      unsupported = @reason_codes - DuplicateReviewCase::RESOLUTION_REASON_CODES
      return if unsupported.empty?

      "Unsupported reason/evidence code: #{unsupported.join(', ')}"
    end

    def admin_actor?
      @actor.respond_to?(:admin?) && @actor.admin?
    end

    def lock_user_participants!
      subject_id = @duplicate_review_case.subject_user_id
      locked_users = User.lock_for_merge_integrity!(@actor.id, subject_id)
      @actor = locked_users.fetch(@actor.id)
      raise StaleCaseError, 'Admin actor is no longer eligible' unless @actor.admin? && @actor.public_login_active?

      @locked_subject = locked_users[subject_id]
    end

    def resolve_case!
      @duplicate_review_case.update!(
        status: NON_MERGE_STATUS,
        resolution_determination: NON_MERGE_DETERMINATION,
        resolution_rationale: @rationale,
        resolution_metadata: resolution_metadata,
        resolved_by: @actor,
        resolved_at: Time.current
      )
    end

    def resolution_metadata
      metadata = {}
      metadata['reason_codes'] = @reason_codes if @reason_codes.any?
      metadata
    end

    def sync_subject_review_flag!
      return if @locked_subject.blank?

      remaining = DuplicateReviewCase.open_cases.for_subject(@locked_subject).where.not(id: @duplicate_review_case.id).exists?
      @locked_subject.update!(needs_duplicate_review: remaining)
    end

    def log_resolution!
      AuditEventService.log(
        action: 'duplicate_review_case_resolved',
        actor: @actor,
        auditable: @locked_subject || @duplicate_review_case.subject_user,
        metadata: {
          duplicate_review_case_id: @duplicate_review_case.id,
          resolution_determination: NON_MERGE_DETERMINATION,
          rationale: @rationale,
          reason_codes: @reason_codes
        }
      )
    end
  end
end
