# frozen_string_literal: true

module DuplicateReviewCases
  class CreateService < BaseService
    CandidateInput = Struct.new(:user, :match_reason, :snapshot)

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
      return failure('Reason codes are required') if @reason_codes.empty?

      existing = DuplicateReviewCase.pending_review.find_by(deduplication_key: deduplication_key)
      if existing
        sync_subject_review_flag!(existing)
        return success(nil, { duplicate_review_case: existing, idempotent: true })
      end

      duplicate_review_case = nil

      ActiveRecord::Base.transaction do
        duplicate_review_case = create_open_case!
        upsert_candidates!(duplicate_review_case)
        sync_subject_review_flag!(duplicate_review_case)
        log_case_opened!(duplicate_review_case)
      end

      success(nil, { duplicate_review_case: duplicate_review_case })
    rescue ActiveRecord::RecordNotUnique
      duplicate_review_case = DuplicateReviewCase.pending_review.find_by!(deduplication_key: deduplication_key)
      sync_subject_review_flag!(duplicate_review_case)
      success(nil, { duplicate_review_case: duplicate_review_case, idempotent: true })
    end

    private

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
      candidate_ids = @candidates.filter_map { |candidate| candidate.user&.id }.sort.join(',')
      Digest::SHA256.hexdigest(
        [@source, @subject_user.id, @reason_codes.join(','), candidate_ids].join(':')
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
