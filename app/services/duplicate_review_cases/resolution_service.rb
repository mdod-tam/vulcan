# frozen_string_literal: true

module DuplicateReviewCases
  # Records one review outcome for an actionable duplicate-review case without moving
  # any user-owned data. Same-person confirmation remains exclusively owned by
  # Users::DuplicateMergeService, which performs the audited merge.
  class ResolutionService < BaseService
    class OutcomeError < StandardError; end

    OUTCOMES = {
      'keep_separate' => {
        status: :resolved_keep_separate,
        audit_action: 'duplicate_review_case_resolved'
      },
      'authorized_relationship_confirmed' => {
        status: :resolved_relationship,
        audit_action: 'duplicate_review_case_resolved'
      },
      'needs_more_information' => {
        status: :awaiting_information,
        audit_action: 'duplicate_review_case_awaiting_information'
      },
      'fraud_or_security_review' => {
        status: :security_review,
        audit_action: 'duplicate_review_case_security_review_started'
      }
    }.freeze

    MERGE_ONLY_OUTCOME = 'same_person_confirmed'

    def initialize(duplicate_review_case:, actor:, outcome:, rationale:, reason_codes: [])
      super()
      @duplicate_review_case = duplicate_review_case
      @actor = actor
      @outcome = outcome.to_s.presence
      @rationale = rationale.to_s.strip
      @reason_codes = Array(reason_codes).map(&:to_s).compact_blank.uniq
    end

    def call
      validation_error = preflight
      return failure(validation_error) if validation_error

      ActiveRecord::Base.transaction do
        lock_subject!
        @duplicate_review_case.lock!
        raise OutcomeError, 'Case is no longer in an actionable review state' unless @duplicate_review_case.merge_allowed?
        raise OutcomeError, relationship_required_message if relationship_required?

        record_outcome!
        sync_subject_review_flag!
        log_outcome!
      end

      success('Duplicate review outcome recorded', { duplicate_review_case: @duplicate_review_case })
    rescue OutcomeError => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence.presence || e.message)
    end

    private

    def preflight
      return 'Duplicate review case is required' if @duplicate_review_case.blank?
      return 'Case is not in an actionable review state' unless @duplicate_review_case.merge_allowed?
      return 'An admin actor is required' unless admin_actor?
      return 'A review outcome is required' if @outcome.blank?
      return 'Same-person confirmation requires a merge; use the merge workflow' if @outcome == MERGE_ONLY_OUTCOME
      return 'Unsupported review outcome' unless OUTCOMES.key?(@outcome)
      return 'A rationale is required' if @rationale.blank?

      relationship_required_message if relationship_required?
    end

    def admin_actor?
      @actor.respond_to?(:admin?) && @actor.admin?
    end

    # Merge locks users before cases; using the same order prevents a concurrent
    # resolve/merge pair from deadlocking while each waits on the other's row lock.
    def lock_subject!
      @subject_user = @duplicate_review_case.subject_user
      @subject_user&.lock!
    end

    def relationship_required?
      @outcome == 'authorized_relationship_confirmed' && !@duplicate_review_case.supported_relationship_persisted?
    end

    def relationship_required_message
      'Create the supported guardian or authorized relationship before resolving this case.'
    end

    def record_outcome!
      now = Time.current
      attributes = {
        status: outcome_config.fetch(:status),
        review_rationale: @rationale,
        review_metadata: review_metadata,
        reviewed_by: @actor,
        reviewed_at: now
      }
      attributes.merge!(resolved_by: @actor, resolved_at: now) if terminal_outcome?
      @duplicate_review_case.update!(attributes)
    end

    def outcome_config
      OUTCOMES.fetch(@outcome)
    end

    def terminal_outcome?
      DuplicateReviewCase::TERMINAL_STATUSES.include?(outcome_config.fetch(:status).to_s)
    end

    def review_metadata
      return {} if @reason_codes.empty?

      { 'reason_codes' => @reason_codes }
    end

    def sync_subject_review_flag!
      subject = @subject_user || @duplicate_review_case.subject_user
      return if subject.blank?

      subject.update!(needs_duplicate_review: DuplicateReviewCase.pending_review.for_subject(subject).exists?)
    end

    def log_outcome!
      AuditEventService.log(
        action: outcome_config.fetch(:audit_action),
        actor: @actor,
        auditable: @duplicate_review_case.subject_user,
        metadata: {
          duplicate_review_case_id: @duplicate_review_case.id,
          review_outcome: @outcome,
          resulting_status: @duplicate_review_case.status,
          rationale: @rationale,
          reason_codes: @reason_codes
        }
      )
    end
  end
end
