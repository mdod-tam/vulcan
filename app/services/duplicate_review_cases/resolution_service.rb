# frozen_string_literal: true

module DuplicateReviewCases
  # Resolves an open duplicate review case without moving any data: approve, ignore,
  # or keep-separate. Every resolution records the admin actor, the identity/linking
  # determination, and a required rationale, then clears the subject review flag when
  # no other open case remains. Same-person merges are handled by Users::DuplicateMergeService.
  class ResolutionService < BaseService
    class StaleCaseError < StandardError; end

    ACTIONS = {
      approve: :resolved_approved,
      ignore: :resolved_ignored,
      keep_separate: :resolved_ignored
    }.freeze

    def initialize(duplicate_review_case:, actor:, action:, determination:, rationale:, reason_codes: [])
      super()
      @duplicate_review_case = duplicate_review_case
      @actor = actor
      @action = action.to_s.to_sym
      @determination = determination.to_s.presence
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
      return 'Unsupported resolution action' unless ACTIONS.key?(@action)
      return 'A resolution determination is required' if @determination.blank?
      return 'Unsupported resolution determination' unless DuplicateReviewCase.resolution_determinations.key?(@determination)
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
        status: ACTIONS.fetch(@action),
        resolution_determination: @determination,
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
          resolution_action: @action.to_s,
          resolution_determination: @determination,
          rationale: @rationale,
          reason_codes: @reason_codes
        }
      )
    end
  end
end
