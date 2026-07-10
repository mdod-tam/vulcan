# frozen_string_literal: true

module DuplicateReviewCases
  # Resolves an open duplicate review case without moving any data: approve, ignore,
  # or keep-separate. Every resolution records the admin actor, the identity/linking
  # determination, and a required rationale, then clears the subject review flag when
  # no other open case remains. Same-person merges are handled by Users::DuplicateMergeService.
  class ResolutionService < BaseService
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
        @duplicate_review_case.lock!
        return failure('Case is no longer open') unless @duplicate_review_case.open?

        resolve_case!
        sync_subject_review_flag!
        log_resolution!
      end

      success('Duplicate review case resolved', { duplicate_review_case: @duplicate_review_case })
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

      nil
    end

    def admin_actor?
      @actor.respond_to?(:admin?) && @actor.admin?
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
      subject = @duplicate_review_case.subject_user
      return if subject.blank?

      remaining = DuplicateReviewCase.open_cases.for_subject(subject).where.not(id: @duplicate_review_case.id).exists?
      subject.update!(needs_duplicate_review: remaining)
    end

    def log_resolution!
      AuditEventService.log(
        action: 'duplicate_review_case_resolved',
        actor: @actor,
        auditable: @duplicate_review_case.subject_user,
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
