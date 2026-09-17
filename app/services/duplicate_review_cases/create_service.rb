# frozen_string_literal: true

module DuplicateReviewCases
  class CreateService < BaseService
    class IneligibleParticipantError < StandardError; end

    CandidateInput = Struct.new(:user, :match_reason, :snapshot)

    # The intake writer supplies a freshly verified review inside its business transaction.
    # Cases, candidate evidence and resolution commit with the person/application they describe.
    # rubocop:disable Metrics/PerceivedComplexity -- keep the atomic composition of the existing writers together
    def self.record_paper_decision!(review:, user:, actor:, rationale:, receipt:, application: nil)
      return [] unless review.confirmed? || review.selected?
      raise ArgumentError, 'An open intake transaction is required' unless ActiveRecord::Base.connection.transaction_open?
      raise ArgumentError, 'Explain the identity decision before continuing.' if rationale.to_s.strip.blank?

      selection = review.selected?
      candidates = Array(review.selected_user || review.candidates)
      candidates.map do |candidate|
        result = new(
          source: :paper_intake, subject_user: selection ? nil : user, actor: actor,
          reason_codes: review.reasons,
          candidates: [CandidateInput.new(candidate, review.reasons.first)],
          subject_fingerprint: Applications::PaperIdentityReviewReceipt.identity_fingerprint(review.identity_facts),
          metadata: {
            intake_context: selection ? 'paper_inline_selection' : 'paper_inline_keep_separate',
            intake_role: review.context.to_s, receipt_digest: Digest::SHA256.hexdigest(receipt.to_s),
            application_id: application&.id
          }.compact
        ).call
        raise IneligibleParticipantError, result.message unless result.success?

        review_case = result.data.fetch(:duplicate_review_case)
        next review_case if review_case.resolved?

        resolver = ResolutionService.new(duplicate_review_case: review_case, actor: actor,
                                         rationale: rationale, reason_codes: review.reasons)
        resolution = selection ? resolver.select_existing(candidate) : resolver.call
        raise IneligibleParticipantError, resolution.message unless resolution.success?

        review_case
      end
    end

    # rubocop:enable Metrics/PerceivedComplexity

    def self.deduplication_key_for(source:, subject_user_id:, reason_codes:, candidate_user_ids:)
      Digest::SHA256.hexdigest(
        [source, subject_user_id, Array(reason_codes).map(&:to_s).sort.join(','),
         Array(candidate_user_ids).compact.map(&:to_i).sort.join(',')].join(':')
      )
    end

    # rubocop:disable Metrics/ParameterLists -- explicit service contract for atomic case creation
    def initialize(source:, subject_user:, actor:, reason_codes:, candidates: [], metadata: {}, audit_action: 'duplicate_review_case_opened',
                   subject_fingerprint: nil)
      super()
      @subject_fingerprint = subject_fingerprint
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
      validation_error = preflight
      return failure(validation_error) if validation_error

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

        scope = inline_intake? ? DuplicateReviewCase.all : DuplicateReviewCase.open_cases
        existing = scope.find_by(deduplication_key: deduplication_key)
        if existing
          sync_subject_review_flag!(existing) unless existing.resolved?
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

    def preflight
      return 'Subject user is required for duplicate review case' if @subject_user.blank? && !inline_selection?
      return 'Subject user must be persisted before opening a duplicate review case' if @subject_user && !@subject_user.persisted?
      return 'Actor is required for duplicate review case' if @actor.blank?
      return 'Actor must be persisted before opening a duplicate review case' unless @actor.persisted?
      return 'An admin actor is required' if inline_intake? && !@actor.admin?
      return 'Reason codes are required' if @reason_codes.empty?

      nil
    end

    def inline_intake?
      @source == :paper_intake && @metadata[:intake_context].in?(%w[paper_inline_keep_separate paper_inline_selection])
    end

    def inline_selection?
      inline_intake? && @metadata[:intake_context] == 'paper_inline_selection' && @subject_fingerprint.present?
    end

    # Locks the persisted subject and candidates, then swaps in the freshly locked/reloaded
    # rows (not the pre-lock instances this service was constructed with) for every
    # subsequent read in this transaction.
    def lock_subject_and_candidates!
      persisted_users = ([@subject_user, @actor] + @candidates.filter_map(&:user)).compact.select(&:persisted?)
      locked = User.lock_for_merge_integrity!(*persisted_users)
      @subject_user = locked.fetch(@subject_user.id) if @subject_user
      @actor = locked.fetch(@actor.id)
      @candidates = @candidates.map do |candidate_input|
        next candidate_input if candidate_input.user.blank? || !candidate_input.user.persisted?

        CandidateInput.new(locked.fetch(candidate_input.user.id), candidate_input.match_reason, candidate_input.snapshot)
      end
    end

    def participant_ineligibility_error
      return 'The actor is no longer an eligible active record' unless @actor.public_login_active?

      if inline_intake?
        participants = [@subject_user, *@candidates.filter_map(&:user)].compact
        return 'A reviewed person was merged; review the current records.' if participants.any?(&:merged?)

        return
      end

      return 'The subject is no longer an eligible active record' if @subject_user && !@subject_user.public_login_active?

      ineligible = @candidates.find { |candidate_input| candidate_input.user.present? && !candidate_input.user.public_login_active? }
      return 'A candidate is no longer an eligible active record' if ineligible

      nil
    end

    def create_open_case!
      DuplicateReviewCase.create!(
        source: @source,
        subject_user: @subject_user,
        subject_fingerprint: @subject_fingerprint,
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
      if inline_intake?
        return Digest::SHA256.hexdigest([
          @metadata[:intake_context], @metadata[:intake_role], @metadata[:receipt_digest], @actor.id,
          @subject_fingerprint, @subject_user&.id, *@candidates.filter_map { |candidate| candidate.user&.id }.sort
        ].join(':'))
      end

      self.class.deduplication_key_for(
        source: @source,
        subject_user_id: @subject_user.id,
        reason_codes: @reason_codes,
        candidate_user_ids: @candidates.filter_map { |candidate| candidate.user&.id }
      )
    end

    def case_metadata
      metadata = MetadataSanitizer.build(
        reason_codes: @reason_codes,
        submitted_contact_digest: @metadata[:submitted_contact_digest],
        intake_context: @metadata[:intake_context],
        subject_snapshot: @metadata[:subject_snapshot]
      )
      metadata.merge!(@metadata.slice(:intake_role, :receipt_digest, :application_id).compact) if inline_intake?
      metadata
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
