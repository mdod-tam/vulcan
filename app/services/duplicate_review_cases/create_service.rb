# frozen_string_literal: true

module DuplicateReviewCases
  class CreateService < BaseService
    class IneligibleParticipantError < StandardError; end

    CandidateInput = Struct.new(:user, :match_reason, :snapshot)

    def self.deduplication_key_for(source:, subject_user_id:, reason_codes:, candidate_user_ids:)
      Digest::SHA256.hexdigest(
        [source, subject_user_id, Array(reason_codes).map(&:to_s).sort.join(','),
         Array(candidate_user_ids).compact.map(&:to_i).sort.join(',')].join(':')
      )
    end

    # rubocop:disable Metrics/ParameterLists -- explicit service contract for atomic case creation
    def initialize(source:, subject_user:, actor:, reason_codes:, candidates: [], metadata: {}, audit_action: 'duplicate_review_case_opened')
      super()
      @source = source.to_sym
      @subject_user = subject_user
      @actor = actor
      @reason_codes = Array(reason_codes).map(&:to_s).sort
      @candidates = candidates
      @metadata = metadata.with_indifferent_access
      @audit_action = audit_action
    end
    # rubocop:enable Metrics/ParameterLists

    def call
      return failure('Subject user is required for duplicate review case') if @subject_user.blank?
      return failure('Subject user must be persisted before opening a duplicate review case') unless @subject_user.persisted?
      return failure('Actor is required for duplicate review case') if @actor.blank?
      return failure('Actor must be persisted before opening a duplicate review case') unless @actor.persisted?
      return failure('Reason codes are required') if @reason_codes.empty?

      duplicate_review_case = nil
      idempotent = false

      ActiveRecord::Base.transaction do
        # Lock the persisted subject (and any persisted candidates) before querying for an
        # open case, so a concurrent create/resolve/merge touching the same subject can't
        # interleave with this transaction's read-then-write. Uses the same
        # User.lock_for_merge_integrity! ordering as the merge boundary, so this can never
        # deadlock against it.
        lock_subject_and_candidates!

        # A lock does not validate a stale decision: if a merge retired the subject or a
        # candidate while this transaction waited for the lock, the pre-lock instances this
        # service was constructed with are stale. Fail with zero case/flag/audit effects
        # rather than opening a case that names an already-merged identity.
        ineligibility_error = participant_ineligibility_error
        raise IneligibleParticipantError, ineligibility_error if ineligibility_error

        existing = DuplicateReviewCase.open_cases.find_by(deduplication_key: deduplication_key)
        if existing
          sync_subject_review_flag!(existing)
          duplicate_review_case = existing
          idempotent = true
        else
          duplicate_review_case = create_open_case!
          upsert_candidates!(duplicate_review_case)
          sync_subject_review_flag!(duplicate_review_case)
          log_case_opened!(duplicate_review_case)
        end
      end

      success(nil, { duplicate_review_case: duplicate_review_case, idempotent: idempotent })
    rescue IneligibleParticipantError => e
      failure(e.message)
    end

    private

    # Locks the persisted subject and candidates, then swaps in the freshly locked/reloaded
    # rows (not the pre-lock instances this service was constructed with) for every
    # subsequent read in this transaction.
    def lock_subject_and_candidates!
      persisted_users = ([@subject_user, @actor] + @candidates.filter_map(&:user)).select(&:persisted?)
      locked = User.lock_for_merge_integrity!(*persisted_users)
      @subject_user = locked.fetch(@subject_user.id)
      @actor = locked.fetch(@actor.id)
      @candidates = @candidates.map do |candidate_input|
        next candidate_input if candidate_input.user.blank? || !candidate_input.user.persisted?

        CandidateInput.new(locked.fetch(candidate_input.user.id), candidate_input.match_reason, candidate_input.snapshot)
      end
    end

    def participant_ineligibility_error
      return 'The actor is no longer an eligible active record' unless @actor.public_login_active?
      return 'The subject is no longer an eligible active record' unless @subject_user.public_login_active?

      ineligible = @candidates.find { |candidate_input| candidate_input.user.present? && !candidate_input.user.public_login_active? }
      return 'A candidate is no longer an eligible active record' if ineligible

      nil
    end

    def create_open_case!
      DuplicateReviewCase.create!(
        source: @source,
        subject_user: @subject_user,
        deduplication_key: deduplication_key,
        metadata: case_metadata,
        opened_at: Time.current,
        status: :open
      )
    end

    def upsert_candidates!(duplicate_review_case)
      @candidates.each do |candidate_input|
        user = candidate_input.user
        duplicate_review_case.duplicate_review_case_candidates.find_or_create_by!(
          candidate_user: user,
          match_reason: candidate_input.match_reason
        ) do |record|
          record.snapshot = sanitized_snapshot_for(candidate_input, user)
        end
      end
    end

    def sync_subject_review_flag!(duplicate_review_case)
      return unless duplicate_review_case.subject_user

      duplicate_review_case.subject_user.update!(needs_duplicate_review: true)
    end

    def log_case_opened!(duplicate_review_case)
      AuditEventService.log(
        action: @audit_action,
        actor: @actor,
        auditable: duplicate_review_case.subject_user,
        metadata: {
          duplicate_review_case_id: duplicate_review_case.id,
          source: duplicate_review_case.source,
          reason_codes: @reason_codes
        }
      )
    end

    def deduplication_key
      self.class.deduplication_key_for(
        source: @source,
        subject_user_id: @subject_user.id,
        reason_codes: @reason_codes,
        candidate_user_ids: @candidates.filter_map { |candidate| candidate.user&.id }
      )
    end

    def case_metadata
      MetadataSanitizer.build(
        reason_codes: @reason_codes,
        submitted_contact_digest: @metadata[:submitted_contact_digest],
        intake_context: @metadata[:intake_context],
        subject_snapshot: @metadata[:subject_snapshot]
      )
    end

    def default_snapshot_for(user)
      return {} if user.blank?

      CandidateSnapshotSanitizer.sanitize(
        email_backed_public_portal_account: user.email_backed_public_portal_account?,
        real_email: user.real_email?,
        real_phone: user.real_phone?
      )
    end

    def sanitized_snapshot_for(candidate_input, user)
      raw_snapshot = candidate_input.snapshot.presence || default_snapshot_for(user)
      CandidateSnapshotSanitizer.sanitize(raw_snapshot)
    end
  end
end
