# frozen_string_literal: true

module DuplicateReviewCases
  # Returns an awaiting-information or security-review case to normal, actionable
  # review. It does not alter either user or any linked domain record.
  class ResumeService < BaseService
    class ResumeError < StandardError; end

    def initialize(duplicate_review_case:, actor:, rationale:)
      super()
      @duplicate_review_case = duplicate_review_case
      @actor = actor
      @rationale = rationale.to_s.strip
    end

    def call
      validation_error = preflight
      return failure(validation_error) if validation_error

      previous_status = @duplicate_review_case.status
      ActiveRecord::Base.transaction do
        lock_subject!
        @duplicate_review_case.lock!
        raise ResumeError, 'Case is no longer awaiting follow-up' unless @duplicate_review_case.nonterminal_hold?

        previous_status = @duplicate_review_case.status
        resume_review!
        sync_subject_review_flag!
        log_resume!(previous_status)
      end

      success('Duplicate review returned to normal review', { duplicate_review_case: @duplicate_review_case })
    rescue ResumeError => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence.presence || e.message)
    end

    private

    def preflight
      return 'Duplicate review case is required' if @duplicate_review_case.blank?
      return 'Case is not awaiting follow-up' unless @duplicate_review_case.nonterminal_hold?
      return 'An admin actor is required' unless @actor.respond_to?(:admin?) && @actor.admin?
      return 'A rationale is required' if @rationale.blank?

      nil
    end

    # DuplicateMergeService locks users before cases, so resume follows that order too.
    def lock_subject!
      @subject_user = @duplicate_review_case.subject_user
      @subject_user&.lock!
    end

    def resume_review!
      @duplicate_review_case.update!(
        status: :open,
        review_rationale: @rationale,
        review_metadata: {},
        reviewed_by: @actor,
        reviewed_at: Time.current,
        resolved_by: nil,
        resolved_at: nil
      )
    end

    def sync_subject_review_flag!
      subject = @subject_user || @duplicate_review_case.subject_user
      return if subject.blank?

      subject.update!(needs_duplicate_review: DuplicateReviewCase.pending_review.for_subject(subject).exists?)
    end

    def log_resume!(previous_status)
      AuditEventService.log(
        action: 'duplicate_review_case_returned_to_review',
        actor: @actor,
        auditable: @duplicate_review_case.subject_user,
        metadata: {
          duplicate_review_case_id: @duplicate_review_case.id,
          previous_status: previous_status,
          resulting_status: @duplicate_review_case.status,
          rationale: @rationale
        }
      )
    end
  end
end
