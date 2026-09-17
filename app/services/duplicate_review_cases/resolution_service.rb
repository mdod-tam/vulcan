# frozen_string_literal: true

module DuplicateReviewCases
  # Resolves keep-separate cases and intake selections; stored-person merges retain their owner.
  class ResolutionService < BaseService
    class StaleCaseError < StandardError; end

    NON_MERGE_STATUS = :resolved_ignored
    NON_MERGE_DETERMINATION = 'keep_separate'

    def select_existing(candidate)
      @selected_user = candidate
      call
    end

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

        lock_and_requalify_case_participants!

        resolve_case!
        sync_participant_review_flags!
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
      return 'Invalid existing-person selection' if @selected_user && !valid_selection?
      if !@selected_user && @duplicate_review_case.subject_user_id.blank? && @duplicate_review_case.inline_intake?
        return 'A proposed identity requires an existing-person selection'
      end

      post_import_validation_error || reason_code_error
    end

    def post_import_validation_error
      return unless @duplicate_review_case.post_import_reconciliation?
      return 'Post-import reconciliation requires at least one reason/evidence code' if @reason_codes.empty?
      return 'Post-import reconciliation case must identify exactly one canonical pair' if post_import_pair_ids.blank?

      nil
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
      participant_ids = [@actor.id, *case_participant_ids]
      locked_users = User.lock_for_merge_integrity!(*participant_ids)
      @locked_users = locked_users
      @actor = locked_users.fetch(@actor.id)
      raise StaleCaseError, 'Admin actor is no longer eligible' unless @actor.admin? && @actor.public_login_active?

      @locked_subject = locked_users[subject_id]
      @locked_case_participants = case_participant_ids.filter_map { |id| locked_users[id] }
    end

    def lock_and_requalify_case_participants!
      locked_candidates = @duplicate_review_case.duplicate_review_case_candidates.lock('FOR UPDATE').to_a
      locked_participant_ids = [
        @duplicate_review_case.subject_user_id,
        *locked_candidates.map(&:candidate_user_id)
      ].compact.uniq
      raise StaleCaseError, 'Case participants changed while the resolution was being prepared' unless
        locked_participant_ids.sort == case_participant_ids.sort

      requalify_selected_person! if @selected_user
      return unless @duplicate_review_case.post_import_reconciliation?

      @locked_pair_users = post_import_pair_ids.map { |id| @locked_users.fetch(id) }
      unless @locked_pair_users.all? { |user| user.is_a?(Users::Constituent) && user.public_login_active? }
        raise StaleCaseError, 'Pair participants are no longer eligible active constituents'
      end

      unless DuplicateReconciliation::Population.strict_case_pair_ids(
        @duplicate_review_case,
        candidates: locked_candidates
      ) == post_import_pair_ids
        raise StaleCaseError, 'Post-import reconciliation pair is no longer valid'
      end
      return if DuplicateReconciliation::Population.new.current_match?(*@locked_pair_users)

      raise StaleCaseError, 'The records no longer form a supported name-and-date-of-birth pair'
    end

    def valid_selection?
      @duplicate_review_case.inline_intake? &&
        @duplicate_review_case.metadata['intake_context'] == 'paper_inline_selection' &&
        @duplicate_review_case.subject_user_id.nil? &&
        @duplicate_review_case.duplicate_review_case_candidates.exists?(candidate_user_id: @selected_user.id)
    end

    def requalify_selected_person!
      selected = @locked_users[@selected_user.id]
      eligible = if @duplicate_review_case.metadata['intake_role'] == 'guardian'
                   selected&.paper_guardian_candidate?
                 else
                   selected&.paper_applicant_candidate?
                 end
      raise StaleCaseError, 'Selected person is no longer eligible' unless valid_selection? && eligible
    end

    def determination
      @selected_user ? 'existing_person_selected' : NON_MERGE_DETERMINATION
    end

    def resolve_case!
      @duplicate_review_case.update!(
        status: @selected_user ? :resolved_selected : NON_MERGE_STATUS,
        resolution_determination: determination,
        resolution_rationale: @rationale,
        resolution_metadata: resolution_metadata,
        resolved_by: @actor,
        resolved_at: Time.current
      )
    end

    def resolution_metadata
      metadata = {}
      metadata['selected_user_id'] = @selected_user.id if @selected_user
      metadata['reason_codes'] = @reason_codes if @reason_codes.any?
      metadata
    end

    def sync_participant_review_flags!
      projection = DuplicateReconciliation::ReviewFlagProjection.new
      @locked_case_participants.grep(Users::Constituent).each do |user|
        user.update!(needs_duplicate_review: projection.required_for?(user))
      end
    end

    def case_participant_ids
      @case_participant_ids ||= [
        @duplicate_review_case.subject_user_id,
        *@duplicate_review_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
      ].compact.uniq
    end

    def post_import_pair_ids
      @post_import_pair_ids ||= DuplicateReconciliation::Population.strict_case_pair_ids(@duplicate_review_case)
    end

    def log_resolution!
      AuditEventService.log(
        action: 'duplicate_review_case_resolved',
        actor: @actor,
        auditable: @locked_subject || @selected_user || @duplicate_review_case,
        metadata: {
          duplicate_review_case_id: @duplicate_review_case.id,
          application_id: @duplicate_review_case.metadata['application_id'],
          resolution_determination: determination,
          rationale: @rationale,
          reason_codes: @reason_codes
        }
      )
    end
  end
end
