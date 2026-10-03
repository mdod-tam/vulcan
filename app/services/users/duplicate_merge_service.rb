# frozen_string_literal: true

module Users
  # Merges a duplicate constituent into a canonical survivor after same-person confirmation.
  #
  # Contract:
  # - Requires an active admin, an open eligible case, confirmation, a rationale,
  #   reason/evidence codes, and explicit contact and delivery choices.
  #   Agreement markers must match the locked records before mutation.
  # - Locks User participants by id, then cases and candidates, applications,
  #   and guardian relationships. Revalidates locked state before mutation.
  #   Pre-commit failures roll back the transaction.
  # - Carries forward or supersedes other open exact-pair post-import cases
  #   without a same/different-person decision. Other related cases involving the duplicate block the merge.
  # - Deactivates the duplicate and records its survivor without deletion.
  # - Emits exactly one +duplicate_user_merged+ audit event per successful merge.
  #
  # Identity and delivery boundaries:
  # - An email-backed survivor keeps its real login email. Synthetic and effective
  #   contact fallbacks do not become stored contact facts.
  # - The delivery choice is independent of login identity.
  # - WebAuthn/TOTP/SMS credentials and reset/recovery state do not transfer.
  #   Canonical credentials remain on their record. Duplicate sessions expire.
  class DuplicateMergeService < BaseService
    class MergeError < StandardError; end
    class IntegrityInventoryChanged < MergeError; end

    SELECTED_SOURCES = %w[canonical duplicate].freeze
    AGREED_SOURCE = 'agreed'
    CONTACT_SOURCES = [*SELECTED_SOURCES, AGREED_SOURCE].freeze
    MERGE_ELIGIBLE_SOURCES = %w[registration_soft_match post_import_reconciliation].freeze
    INTEGRITY_INVENTORY_RETRY_LIMIT = 1

    # rubocop:disable Metrics/ParameterLists -- explicit, auditable merge contract
    def initialize(actor:, duplicate_review_case:, canonical_user:, duplicate_user:,
                   same_person_confirmed:, rationale:, reason_codes: [],
                   contact_choices: {}, delivery_choice: nil)
      super()
      @actor = actor
      @duplicate_review_case = duplicate_review_case
      @canonical_user = canonical_user
      @duplicate_user = duplicate_user
      @same_person_confirmed = same_person_confirmed
      @rationale = rationale.to_s.strip
      @reason_codes = Array(reason_codes).map(&:to_s).compact_blank.uniq
      @contact_choices = (contact_choices || {}).to_h.symbolize_keys
      @delivery_choice = delivery_choice.to_s.presence
      @summary = {}
    end
    # rubocop:enable Metrics/ParameterLists

    def call
      error = static_preflight
      return failure(error) if error

      merge_with_integrity_inventory_retry!

      success('Duplicate record merged', { canonical_user: @canonical_user, duplicate_user: @duplicate_user, summary: @summary })
    rescue MergeError => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence.presence || e.message)
    end

    private

    # A case or relationship can commit between the participant scan and the User locks.
    # Retry the transaction once to include new participants in the lock order.
    # Further inventory changes fail with a retryable error.
    def merge_with_integrity_inventory_retry!
      retries = 0

      begin
        merge_transaction!
      rescue IntegrityInventoryChanged
        raise if retries >= INTEGRITY_INVENTORY_RETRY_LIMIT

        retries += 1
        retry
      end
    end

    def merge_transaction!
      ActiveRecord::Base.transaction(requires_new: true) do
        lock_records!
        recheck_error = post_lock_identity_recheck
        raise MergeError, recheck_error if recheck_error

        agreement_error = agreement_recheck_error
        raise MergeError, agreement_error if agreement_error

        capture_final_contact!
        live_error = live_preflight
        raise MergeError, live_error if live_error

        release_duplicate_contact!
        apply_canonical_contact!
        transfer_applications!
        transfer_guardian_relationships!
        reconcile_person_references!
        expire_duplicate_sessions!
        retire_duplicate!
        reconcile_related_cases!
        audit_event = log_merge!
        resolve_selected_case!(audit_event)
        sync_affected_review_flags!
      end
    end

    # --- Preflight -----------------------------------------------------------

    def static_preflight
      identity_preflight || intent_preflight || contact_choice_error || delivery_choice_error
    end

    def identity_preflight
      return 'An admin actor is required' unless admin_actor?
      return 'An open duplicate review case is required' unless open_case?
      return 'Both canonical and duplicate users are required' if @canonical_user.blank? || @duplicate_user.blank?
      return 'Users must be persisted' unless @canonical_user.persisted? && @duplicate_user.persisted?
      return 'Canonical and duplicate users must be different' if @canonical_user.id == @duplicate_user.id
      return 'Only constituent records can be merged' unless both_constituents?

      pair_membership_error || canonical_eligibility_error || login_authority_error
    end

    def pair_membership_error
      return 'The review case subject must be one of the two records' unless subject_in_pair?
      return 'The other record must be a recorded candidate of this case' unless other_is_recorded_candidate?
      return 'This case source is not eligible for the duplicate merge workflow' unless merge_eligible_source?

      reconciliation_error = post_import_pair_error
      return reconciliation_error if reconciliation_error

      nil
    end

    # Like the controller, require the case subject and one recorded candidate.
    # A candidate/candidate pair is outside the merge contract.
    def subject_in_pair?
      [@canonical_user.id, @duplicate_user.id].include?(@duplicate_review_case.subject_user_id)
    end

    def other_is_recorded_candidate?
      subject_id = @duplicate_review_case.subject_user_id
      other_id = subject_id == @canonical_user.id ? @duplicate_user.id : @canonical_user.id
      @duplicate_review_case.duplicate_review_case_candidates.pluck(:candidate_user_id).compact.include?(other_id)
    end

    # Only registration_soft_match and exact-pair post_import_reconciliation cases qualify.
    # support_claim, paper_intake, and admin_create cases require separate resolution.
    def merge_eligible_source?
      MERGE_ELIGIBLE_SOURCES.include?(@duplicate_review_case.source)
    end

    def post_import_pair_error
      return unless @duplicate_review_case.post_import_reconciliation?

      expected_ids = [@canonical_user.id, @duplicate_user.id].sort
      actual_ids = @duplicate_review_case.strict_post_import_pair_ids
      return 'The post-import reconciliation case no longer identifies this exact pair' unless actual_ids == expected_ids
      return if DuplicateReconciliation::Population.new.current_match?(@canonical_user, @duplicate_user)

      'The post-import reconciliation pair no longer has the supported name-and-date-of-birth match'
    end

    # An inactive, suspended, or merged survivor cannot receive contact or extend a merge chain.
    def canonical_eligibility_error
      return 'The canonical survivor has already been merged into another record' if @canonical_user.merged?
      return 'The canonical survivor must be an active record (not inactive or suspended)' unless @canonical_user.public_login_active?

      nil
    end

    # Revalidate the duplicate under lock too. Inactive or suspended status can indicate
    # an unresolved security hold that a merge must not absorb.
    def duplicate_eligibility_error
      return 'The duplicate record has already been merged' if @duplicate_user.merged?
      return 'The duplicate record must be an active record (not inactive or suspended) to merge' unless @duplicate_user.public_login_active?

      nil
    end

    # Choose the email-backed record as canonical so its login email, password, and MFA stay together.
    # An email-backed canonical must retain its own email, even if both records have email.
    # The duplicate's email must not gain access through the canonical's credentials.
    def login_authority_error
      return 'The email-backed record must be chosen as canonical so its password and MFA survive the merge' if wrong_record_chosen_as_canonical?
      return "The canonical record's own login email must survive the merge; it cannot be replaced with the duplicate's email" if canonical_email_would_be_replaced?

      nil
    end

    def wrong_record_chosen_as_canonical?
      @duplicate_user.email_backed_public_portal_account? && !@canonical_user.email_backed_public_portal_account?
    end

    def canonical_email_would_be_replaced?
      @canonical_user.email_backed_public_portal_account? && final_email_source == 'duplicate'
    end

    def intent_preflight
      return 'Same-person confirmation is required to merge' unless same_person_confirmed?
      return 'A rationale is required' if @rationale.blank?
      return 'At least one reason/evidence code is required' if @reason_codes.empty?

      reason_code_error || duplicate_eligibility_error
    end

    # Reason codes become immutable case metadata and audit evidence.
    # Validate them before mutation to return specific preflight errors to the admin.
    def reason_code_error
      return "Too many reason/evidence codes (maximum #{DuplicateReviewCase::MAX_REASON_CODES})" if
        @reason_codes.length > DuplicateReviewCase::MAX_REASON_CODES

      unsupported = @reason_codes - DuplicateReviewCase::RESOLUTION_REASON_CODES
      return if unsupported.empty?

      "Unsupported reason/evidence code: #{unsupported.join(', ')}"
    end

    # Require explicit choices or current agreement so audit metadata reflects the admin's review.
    # Missing or invalid values must not default to canonical.
    def contact_choice_error
      %i[email phone address].each do |field|
        source = @contact_choices[field].to_s.presence
        return "An explicit #{field} choice or current agreement is required" if source.blank?

        allowed_sources = field == :email ? SELECTED_SOURCES : CONTACT_SOURCES
        return "Invalid #{field} choice" unless allowed_sources.include?(source)
      end
      nil
    end

    # Delivery remains independent of login identity. Require an explicit choice or current
    # agreement, with no default to canonical for missing or invalid values.
    def delivery_choice_error
      return 'An explicit delivery route choice or current agreement is required' if @delivery_choice.blank?
      return 'Invalid delivery route choice' unless CONTACT_SOURCES.include?(@delivery_choice)

      nil
    end

    # A collapsed form row claims exact agreement between both records.
    # After the locks, reject stale or forged agreement before contact capture, mutation, or audit.
    def agreement_recheck_error
      checks = {
        phone: final_phone_source,
        phone_type: @contact_choices[:phone_type].to_s,
        address: final_address_source,
        delivery: @delivery_choice
      }
      checks.each do |fact, source|
        next unless source == AGREED_SOURCE
        next if duplicate_merge_facts.agreed?(fact)

        return "The #{agreement_label(fact)} no longer agree; reload the case and review the current records"
      end
      nil
    end

    def agreement_label(fact)
      {
        phone: 'phone values',
        phone_type: 'phone types',
        address: 'addresses',
        delivery: 'official-notice delivery routes'
      }.fetch(fact)
    end

    def live_preflight
      return 'Case is no longer open' unless @duplicate_review_case.open?
      return duplicate_eligibility_error if duplicate_eligibility_error
      return 'The duplicate record has a pending recovery request; resolve it before merging' if duplicate_pending_recovery?

      secure_request_error = secure_request_merge_error
      return secure_request_error if secure_request_error
      return @related_case_reconciler.error unless @related_case_reconciler.valid?
      return application_conflict_message if application_conflict?
      return @guardian_relationship_plan.error unless @guardian_relationship_plan.valid?

      contact_result_error
    end

    def contact_result_error
      return 'The chosen email is not a real email address' if final_email_invalid?
      return 'Merging would strand an email-backed login; keep the email-backed record\'s email as the surviving email' if strands_portal_account?
      return 'A real surviving phone requires an explicit phone type' if phone_type_missing?
      return 'Invalid phone type' if phone_type_invalid?
      return 'The chosen phone is not a real phone number' if final_phone_invalid?

      nil
    end

    # --- Contact resolution --------------------------------------------------

    # contact_choice_error validates source choices before contact capture or mutation.
    def final_email_source
      @contact_choices[:email].to_s
    end

    def final_phone_source
      @contact_choices[:phone].to_s
    end

    def final_address_source
      @contact_choices[:address].to_s
    end

    def email_source_user
      final_email_source == 'duplicate' ? @duplicate_user : @canonical_user
    end

    def phone_source_user
      final_phone_source == 'duplicate' ? @duplicate_user : @canonical_user
    end

    def address_source_user
      final_address_source == 'duplicate' ? @duplicate_user : @canonical_user
    end

    # Capture selected contact values under lock before the duplicate clears its email and phone
    # for the unique indexes. The canonical update must use this snapshot.
    def capture_final_contact!
      @captured_email = email_source_user.email
      @captured_phone = phone_source_user.phone
      @captured_address = {
        physical_address_1: address_source_user.physical_address_1,
        physical_address_2: address_source_user.physical_address_2,
        city: address_source_user.city,
        state: address_source_user.state,
        zip_code: address_source_user.zip_code
      }
    end

    def final_email
      @captured_email
    end

    def final_phone
      @captured_phone
    end

    def final_phone_type
      return @canonical_user.phone_type.to_s.presence if @contact_choices[:phone_type].to_s == AGREED_SOURCE

      @contact_choices[:phone_type].to_s.presence
    end

    def duplicate_merge_facts
      DuplicateMergeFacts.new(@canonical_user, @duplicate_user)
    end

    def final_phone_real?
      phone_source_user.real_phone?
    end

    def final_email_invalid?
      return false if final_email.blank?

      !email_source_user.real_email?
    end

    def final_phone_invalid?
      return false if final_phone.blank?

      !final_phone_real?
    end

    # If either record has email-backed portal access, the survivor needs a real email to preserve login access.
    def strands_portal_account?
      return false unless either_is_email_backed_portal?

      !email_source_user.real_email?
    end

    def either_is_email_backed_portal?
      @canonical_user.email_backed_public_portal_account? || @duplicate_user.email_backed_public_portal_account?
    end

    def phone_type_missing?
      final_phone_real? && final_phone_type.blank?
    end

    # Exclude legacy contact_email and contact_letter values from phone_type, as the form does.
    # These values describe other delivery routes. Notifications display phone_type as the preferred contact method.
    def phone_type_invalid?
      return false if final_phone_type.blank?

      User::REAL_PHONE_TYPES.exclude?(final_phone_type.to_s)
    end

    # --- Mutations -----------------------------------------------------------

    # Lock participants through +User.lock_for_merge_integrity!+ in ascending id order.
    # Include the actor, merge pair, relationship neighbors, and related case participants.
    # Then lock cases, candidates, applications, and guardian relationships.
    # Portal submission/autosave, contact edits, and secure-request issuance share the User lock order.
    def lock_records!
      integrity_user_ids = [
        @actor.id,
        @canonical_user.id,
        @duplicate_user.id,
        *relationship_neighbor_user_ids,
        *related_open_case_participant_ids
      ].uniq
      locked_users = User.lock_for_merge_integrity!(*integrity_user_ids)
      @locked_users = locked_users
      @actor = locked_users.fetch(@actor.id)
      @canonical_user = locked_users.fetch(@canonical_user.id)
      @duplicate_user = locked_users.fetch(@duplicate_user.id)

      lock_case_inventory!
      lock_application_inventory!
      lock_guardian_relationship_inventory!
      ensure_integrity_inventory_is_fully_locked!
      @related_case_reconciler = DuplicateReconciliation::RelatedCaseReconciler.new(
        selected_case: @duplicate_review_case,
        canonical_user: @canonical_user,
        duplicate_user: @duplicate_user,
        actor: @actor,
        cases: @locked_case_rows,
        candidate_rows: @locked_case_candidate_rows,
        locked_users: @locked_users
      )
    end

    def lock_case_inventory!
      case_ids = (related_open_case_ids + [@duplicate_review_case.id]).uniq
      @locked_case_rows = DuplicateReviewCase.where(id: case_ids).order(:id).lock('FOR UPDATE').to_a
      @duplicate_review_case = @locked_case_rows.find { |review_case| review_case.id == @duplicate_review_case.id }
      raise MergeError, 'The selected duplicate review case is no longer available' unless @duplicate_review_case

      @locked_case_candidate_rows = DuplicateReviewCaseCandidate
                                    .where(duplicate_review_case_id: case_ids)
                                    .order(:duplicate_review_case_id, :id)
                                    .lock('FOR UPDATE')
                                    .to_a
    end

    def related_open_case_ids
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      candidate_case_ids = DuplicateReviewCaseCandidate.where(candidate_user_id: participant_ids)
                                                       .select(:duplicate_review_case_id)
      DuplicateReviewCase.open_cases
                         .where(subject_user_id: participant_ids)
                         .or(DuplicateReviewCase.open_cases.where(id: candidate_case_ids))
                         .pluck(:id)
    end

    def related_open_case_participant_ids
      case_ids = related_open_case_ids
      subject_ids = DuplicateReviewCase.where(id: case_ids).pluck(:subject_user_id)
      candidate_ids = DuplicateReviewCaseCandidate.where(duplicate_review_case_id: case_ids).pluck(:candidate_user_id)
      (subject_ids + candidate_ids).compact
    end

    def relationship_neighbor_user_ids
      relationship_inventory_scope.pluck(:guardian_id, :dependent_id).flatten.uniq
    end

    # A guardian merge can coalesce relationships for the same dependent.
    # Include all co-guardians so contact-priority checks use the complete locked relationship set.
    def relationship_inventory_scope
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      affected_dependent_ids = GuardianRelationship.where(guardian_id: participant_ids).select(:dependent_id)

      GuardianRelationship.where(dependent_id: participant_ids)
                          .or(GuardianRelationship.where(dependent_id: affected_dependent_ids))
    end

    # Lock owned and managed applications before conflict checks or transfer.
    # Concurrent writers that need these locks wait until the transaction ends.
    def lock_application_inventory!
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      @locked_applications = Application.where(user_id: participant_ids)
                                        .or(Application.where(managing_guardian_id: participant_ids))
                                        .order(:id)
                                        .lock('FOR UPDATE')
                                        .load
    end

    # Build the relationship projection from locked rows.
    # +create_guardian_relationship+ locks both User endpoints first, so it waits until this merge ends.
    def lock_guardian_relationship_inventory!
      @locked_guardian_relationships = relationship_inventory_scope.order(:id).lock('FOR UPDATE').load
      @guardian_relationship_plan = DuplicateMergeRelationshipPlan.new(
        canonical_user: @canonical_user,
        duplicate_user: @duplicate_user,
        relationships: @locked_guardian_relationships
      )
    end

    # Case and relationship writers lock their User participants first.
    # A commit before our User locks can add a participant to the inventory.
    # A late lock could violate ascending order. Retry with the complete participant set instead.
    def ensure_integrity_inventory_is_fully_locked!
      relationship_user_ids = @locked_guardian_relationships.flat_map do |relationship|
        [relationship.guardian_id, relationship.dependent_id]
      end
      case_user_ids = @locked_case_rows.flat_map do |review_case|
        [review_case.subject_user_id,
         *@locked_case_candidate_rows.select do |candidate|
           candidate.duplicate_review_case_id == review_case.id
         end.map(&:candidate_user_id)]
      end
      missing_ids = (relationship_user_ids + case_user_ids).compact.uniq - @locked_users.keys
      return if missing_ids.empty?

      raise IntegrityInventoryChanged, 'Related records changed while the merge was being prepared; reload and try again'
    end

    # Locks alone do not validate stale decisions.
    # Revalidate actor authority, constituent roles, pair membership, and survivor eligibility from the locked rows.
    def post_lock_identity_recheck
      return 'An admin actor is required' unless admin_actor?
      return 'Only constituent records can be merged' unless both_constituents?

      pair_membership_error || canonical_eligibility_error || login_authority_error
    end

    # Clear both duplicate contacts, including values that do not transfer, to release unique
    # values and remove the retired record from public contact lookup.
    # Selected values are safe in the snapshot from +capture_final_contact!+.
    #
    # UserAuthentication fingerprints normalized email and phone for :password_reset tokens.
    # Contact removal invalidates duplicate tokens that include those contacts.
    # A changed canonical phone invalidates tokens sent to the discarded number.
    # A delivery-preference change alone does not change this fingerprint.
    def release_duplicate_contact!
      mark_duplicate_retiring!
      @duplicate_user.update!(email: nil, phone: nil, phone_type: nil)
    end

    def mark_duplicate_retiring!
      @duplicate_user.merge_in_progress = true
      @duplicate_user.retiring_for_merge = true
    end

    def apply_canonical_contact!
      @canonical_user.merge_in_progress = true
      @canonical_user.update!(canonical_contact_attributes)
    end

    def canonical_contact_attributes
      attrs = {
        email: final_email,
        phone: final_phone,
        phone_type: final_phone.present? ? final_phone_type : nil,
        communication_preference: final_communication_preference
      }
      attrs.merge!(address_attributes)
      attrs
    end

    def address_attributes
      @captured_address
    end

    def final_communication_preference
      source = @delivery_choice == 'duplicate' ? @duplicate_user : @canonical_user
      source.communication_preference
    end

    def transfer_applications!
      transfer_owned_applications!
      transfer_managed_applications!
    end

    # Transfer ownership from the locked inventory without changes to lifecycle status, history, or audit.
    # update_all skips managing_guardian_cannot_be_applicant. Clear the canonical guardian first
    # so an applicant cannot manage their own application.
    def transfer_owned_applications!
      ids = selected_application_ids
      @summary[:applications_transferred] = ids.size
      return if ids.empty?

      owned = Application.where(id: ids)
      owned.where(managing_guardian_id: @canonical_user.id)
           .update_all(managing_guardian_id: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      owned.update_all(user_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Transfer guardian management from the locked inventory.
    # Clear the guardian on canonical-owned applications to prevent self-management.
    def transfer_managed_applications!
      managed = @locked_applications.select { |app| app.managing_guardian_id == @duplicate_user.id }
      self_managed_ids = managed.select { |app| app.user_id == @canonical_user.id }.map(&:id)
      transferable_ids = managed.reject { |app| app.user_id == @canonical_user.id }.map(&:id)
      @summary[:managed_applications_transferred] = transferable_ids.size
      @summary[:managed_applications_guardian_cleared] = self_managed_ids.size

      Application.where(id: self_managed_ids).update_all(managing_guardian_id: nil, updated_at: Time.current) if self_managed_ids.any? # rubocop:disable Rails/SkipsModelValidations
      Application.where(id: transferable_ids).update_all(managing_guardian_id: @canonical_user.id, updated_at: Time.current) if transferable_ids.any? # rubocop:disable Rails/SkipsModelValidations
    end

    # Transfer all duplicate-owned applications from the locked inventory.
    # A partial transfer could strand applications on the retired record or evade the conflict check.
    def selected_application_ids
      @locked_applications.select { |app| app.user_id == @duplicate_user.id }.map(&:id)
    end

    def transfer_guardian_relationships!
      @summary.merge!(@guardian_relationship_plan.apply!)
    end

    # Evaluations follow the transferred applications so evaluation.constituent matches evaluation.application.user.
    # Print items and notifications retain their historical owners. Cancel unreleased print items
    # because a new recipient requires a newly authorized artifact.
    def reconcile_person_references!
      @summary[:evaluations_transferred] =
        Evaluation.where(constituent_id: @duplicate_user.id)
                  .update_all(constituent_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      @summary[:pending_print_queue_items_canceled] =
        Letters::Delivery.cancel_for_recipient_change!(recipient_id: @duplicate_user.id, actor: @actor)
    end

    def expire_duplicate_sessions!
      @summary[:sessions_expired] = @duplicate_user.sessions.count
      @duplicate_user.sessions.destroy_all
    end

    def retire_duplicate!
      mark_duplicate_retiring!
      @duplicate_user.update!(
        status: :inactive,
        merged_into_user: @canonical_user,
        merged_by: @actor,
        merged_at: Time.current,
        needs_duplicate_review: false,
        reset_password_token: nil,
        reset_password_sent_at: nil
      )
    end

    def reconcile_related_cases!
      @summary.merge!(@related_case_reconciler.apply!)
    end

    # Only the selected case receives the same-person decision.
    # Other open exact-pair post-import cases can move or become superseded without a same/different determination.
    def resolve_selected_case!(audit_event)
      @duplicate_review_case.update!(
        status: :resolved_merged,
        resolution_determination: :same_person_confirmed,
        resolution_rationale: @rationale,
        resolution_metadata: case_resolution_metadata(audit_event),
        resolved_by: @actor,
        resolved_at: Time.current
      )
    end

    def case_resolution_metadata(audit_event)
      {
        'reason_codes' => @reason_codes,
        'canonical_user_id' => @canonical_user.id,
        'merged_user_id' => @duplicate_user.id,
        'contact_choices' => sanitized_contact_choices,
        'delivery_choice' => @delivery_choice,
        'transfer_summary' => @summary.transform_keys(&:to_s),
        'merge_audit_event_id' => audit_event&.id
      }
    end

    def sanitized_contact_choices
      {
        'email' => final_email_source,
        'phone' => final_phone_source,
        'phone_type' => final_phone_type,
        'address' => final_address_source
      }
    end

    def sync_affected_review_flags!
      projection = DuplicateReconciliation::ReviewFlagProjection.new
      user_ids = [@canonical_user.id, *@related_case_reconciler.affected_user_ids].uniq - [@duplicate_user.id]
      user_ids.filter_map { |id| @locked_users[id] }.grep(Users::Constituent).each do |user|
        user.update!(needs_duplicate_review: projection.required_for?(user))
      end
    end

    def log_merge!
      AuditEventService.log(
        action: 'duplicate_user_merged',
        actor: @actor,
        auditable: @canonical_user,
        metadata: {
          duplicate_review_case_id: @duplicate_review_case.id,
          canonical_user_id: @canonical_user.id,
          merged_user_id: @duplicate_user.id,
          resolution_determination: 'same_person_confirmed',
          rationale: @rationale,
          reason_codes: @reason_codes,
          contact_choices: sanitized_contact_choices,
          delivery_choice: @delivery_choice,
          transfer_summary: @summary.transform_keys(&:to_s)
        }
      )
    end

    # --- Live blocker checks -------------------------------------------------

    def duplicate_pending_recovery?
      @duplicate_user.recovery_requests.pending.exists?
    end

    def duplicate_active_secure_forms?
      SecureRequestForm.active.where(recipient_id: @duplicate_user.id)
                       .or(SecureRequestForm.active.where(delivery_owner_id: @duplicate_user.id))
                       .exists?
    end

    def secure_request_merge_error
      if SecureRequestForm.active.with_incomplete_delivery_provenance.exists?
        return 'Active legacy secure request forms have unresolved delivery ownership; revoke them or wait for expiry before merging'
      end

      active_form_error =
        'The duplicate record is a recipient or delivery owner of an active secure request form; revoke it before merging'
      return active_form_error if duplicate_active_secure_forms?
      return unless canonical_delivery_contact_would_change?

      'The merge would discard contact used by an active secure request form; revoke it or keep that contact before merging'
    end

    def canonical_delivery_contact_would_change?
      SecureRequestForm.active.where(delivery_owner_id: @canonical_user.id).any? do |form|
        case form.recipient_channel
        when 'email'
          User.normalize_email(form.recipient_email) != User.normalize_email(final_email)
        when 'sms'
          User.normalize_phone(form.recipient_phone) != User.normalize_phone(final_phone)
        when 'letter'
          final_address_source == 'duplicate'
        else
          true
        end
      end
    end

    # Use the locked inventory so conflict detection and application transfer cover the same rows.
    def application_conflict?
      canonical_blocking = @locked_applications.count { |app| app.user_id == @canonical_user.id && app.blocking_new_submission? }
      duplicate_blocking = @locked_applications.count { |app| app.user_id == @duplicate_user.id && app.blocking_new_submission? }
      (canonical_blocking + duplicate_blocking) > 1
    end

    def application_conflict_message
      'Merging would leave the canonical record with more than one active application; archive or reject one first'
    end

    # --- Guards --------------------------------------------------------------

    def admin_actor?
      @actor.respond_to?(:admin?) && @actor.admin? && @actor.public_login_active?
    end

    def open_case?
      @duplicate_review_case.present? && @duplicate_review_case.open?
    end

    def both_constituents?
      @canonical_user.is_a?(Users::Constituent) && @duplicate_user.is_a?(Users::Constituent)
    end

    def same_person_confirmed?
      ActiveModel::Type::Boolean.new.cast(@same_person_confirmed) == true
    end
  end
end
