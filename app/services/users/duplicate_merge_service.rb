# frozen_string_literal: true

module Users
  # Same-person merge of a duplicate constituent record into a canonical survivor.
  #
  # Contract:
  # - Requires an admin actor, an open merge-eligible duplicate review case,
  #   explicit same-person confirmation, a rationale, evidence/reason codes, and explicit
  #   contact and delivery decisions. Exact shared values may arrive as agreement markers,
  #   which are rechecked under the same locks before any mutation.
  # - Locks the actor, both users, the case, its candidate row, and the complete
  #   application and guardian/dependent relationship inventories (in that order);
  #   preflights every blocker against the
  #   requalified locked state; then performs all mutations with bang persistence inside a
  #   single transaction and rolls back on failure.
  # - Carries other open exact-pair post-import cases from the retiring record to the
  #   survivor without deciding them. Cases outside that narrow contract still fail closed.
  # - Retires (deactivates) the duplicate and points it at the canonical survivor; it is
  #   never destroyed.
  # - Emits exactly one +duplicate_user_merged+ audit event.
  #
  # Concept boundaries preserved:
  # - Login identity: the canonical survivor keeps a real email if it was email-backed;
  #   synthetic/effective fallback values never become stored contact truth.
  # - Delivery route: chosen independently from login identity.
  # - Auth artifacts (WebAuthn/TOTP/SMS credentials, reset/recovery state) are never
  #   transferred; the canonical user's auth state is preserved and duplicate sessions expire.
  class DuplicateMergeService < BaseService
    class MergeError < StandardError; end

    SELECTED_SOURCES = %w[canonical duplicate].freeze
    AGREED_SOURCE = 'agreed'
    CONTACT_SOURCES = [*SELECTED_SOURCES, AGREED_SOURCE].freeze
    MERGE_ELIGIBLE_SOURCES = %w[registration_soft_match post_import_reconciliation].freeze

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

      ActiveRecord::Base.transaction do
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

      success('Duplicate record merged', { canonical_user: @canonical_user, duplicate_user: @duplicate_user, summary: @summary })
    rescue MergeError => e
      failure(e.message)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence.presence || e.message)
    end

    private

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

    # Defense in depth mirroring the controller's pair scoping: the pair must be the case
    # subject plus one of its recorded candidates, never an off-UI candidate/candidate pair.
    def subject_in_pair?
      [@canonical_user.id, @duplicate_user.id].include?(@duplicate_review_case.subject_user_id)
    end

    def other_is_recorded_candidate?
      subject_id = @duplicate_review_case.subject_user_id
      other_id = subject_id == @canonical_user.id ? @duplicate_user.id : @canonical_user.id
      @duplicate_review_case.duplicate_review_case_candidates.pluck(:candidate_user_id).compact.include?(other_id)
    end

    # PR4b's merge path accepts online-registration probable duplicates and the narrowly
    # pair-scoped post-import reconciliation source. Staff-initiated
    # support_claim/paper_intake/admin_create cases remain outside this contract.
    def merge_eligible_source?
      MERGE_ELIGIBLE_SOURCES.include?(@duplicate_review_case.source)
    end

    def post_import_pair_error
      return unless @duplicate_review_case.post_import_reconciliation?

      expected_ids = [@canonical_user.id, @duplicate_user.id].sort
      actual_ids = DuplicateReconciliation::Population.strict_case_pair_ids(
        @duplicate_review_case,
        candidates: @locked_candidate_rows
      )
      return 'The post-import reconciliation case no longer identifies this exact pair' unless actual_ids == expected_ids
      return if DuplicateReconciliation::Population.new.current_match?(@canonical_user, @duplicate_user)

      'The post-import reconciliation pair no longer has the supported name-and-date-of-birth match'
    end

    # The survivor must be a live, active record. Merging into a retired, inactive, or
    # suspended account would corrupt merge chains or apply contact to a dead record.
    def canonical_eligibility_error
      return 'The canonical survivor has already been merged into another record' if @canonical_user.merged?
      return 'The canonical survivor must be an active record (not inactive or suspended)' unless @canonical_user.public_login_active?

      nil
    end

    # Both identities' active/retired status are requalified under lock, not just the
    # canonical's: a suspended or already-inactive duplicate is a distinct admin condition
    # (e.g. a fraud/security hold) that merging must not silently absorb or launder through
    # retirement. Staff resolve that condition on its own terms before merging.
    def duplicate_eligibility_error
      return 'The duplicate record has already been merged' if @duplicate_user.merged?
      return 'The duplicate record must be an active record (not inactive or suspended) to merge' unless @duplicate_user.public_login_active?

      nil
    end

    # Login identity invariant (both halves): if the duplicate is email-backed and the
    # canonical is not, the wrong record was chosen as canonical -- the duplicate already
    # carries the password/MFA the person authenticates with. And whenever the canonical
    # *is* email-backed (whether or not the duplicate also is), its own email must survive;
    # replacing it with the duplicate's would grant portal access under credentials the
    # person never set, even though the canonical's password/MFA never move.
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

    # Reason codes become immutable resolution metadata and audit evidence, so they are checked
    # against the server-owned vocabulary here -- as a clean preflight failure the admin can act
    # on -- rather than only at the model, where ResolutionService#resolve_case!-style update!
    # calls would surface an unhandled RecordInvalid instead.
    def reason_code_error
      return "Too many reason/evidence codes (maximum #{DuplicateReviewCase::MAX_REASON_CODES})" if
        @reason_codes.length > DuplicateReviewCase::MAX_REASON_CODES

      unsupported = @reason_codes - DuplicateReviewCase::RESOLUTION_REASON_CODES
      return if unsupported.empty?

      "Unsupported reason/evidence code: #{unsupported.join(', ')}"
    end

    # Each contact fact must be an explicit admin decision or a current exact agreement,
    # never an inferred default. A missing or garbage value must block the merge rather
    # than silently resolve to "canonical" and let the audit metadata misrepresent what
    # the admin reviewed.
    def contact_choice_error
      %i[email phone address].each do |field|
        source = @contact_choices[field].to_s.presence
        return "An explicit #{field} choice or current agreement is required" if source.blank?

        allowed_sources = field == :email ? SELECTED_SOURCES : CONTACT_SOURCES
        return "Invalid #{field} choice" unless allowed_sources.include?(source)
      end
      nil
    end

    # Delivery remains independent from login identity (see the merge inventory). The
    # form either records a choice between differing values or claims exact agreement;
    # a missing or invalid value must not silently fall back to canonical.
    def delivery_choice_error
      return 'An explicit delivery route choice or current agreement is required' if @delivery_choice.blank?
      return 'Invalid delivery route choice' unless CONTACT_SOURCES.include?(@delivery_choice)

      nil
    end

    # A collapsed form row is a claim about both locked records, not permission to silently pick
    # one. Recheck every such claim after the standard merge-integrity locks and fail before any
    # contact capture, mutation, or audit if the page is stale or the marker was forged.
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

    # Blockers that depend on live, locked state.
    def live_preflight
      return 'Case is no longer open' unless @duplicate_review_case.open?
      return duplicate_eligibility_error if duplicate_eligibility_error
      return 'The duplicate record has a pending recovery request; resolve it before merging' if duplicate_pending_recovery?
      return 'The duplicate record is the recipient of an active secure request form; revoke it before merging' if duplicate_active_secure_forms?
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

    # Preflight's contact_choice_error already rejected blank/invalid values, so these
    # always resolve an explicit admin choice by the time mutations run.
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

    # Snapshot the surviving contact facts under lock, before the duplicate releases
    # any moved email/phone, so applying them to the canonical record cannot read a
    # value that was just nulled to satisfy the unique indexes.
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

    # An email-backed record's login email must survive the merge. Whenever either the
    # canonical or the retiring duplicate is an email-backed portal account, the surviving
    # canonical must end with a real email; otherwise the person loses their login.
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

    # Only a real telephone route may survive as the canonical's phone_type. The full
    # phone_type enum also carries the legacy non-phone contact modes contact_email and
    # contact_letter, which the merge form never offers -- accepting them would let a forged
    # request store "reach this person by email" as the canonical's phone preference, which
    # then renders as their preferred contact method in evaluator and trainer notifications.
    def phone_type_invalid?
      return false if final_phone_type.blank?

      User::REAL_PHONE_TYPES.exclude?(final_phone_type.to_s)
    end

    # --- Mutations -----------------------------------------------------------

    # Deterministic lock order (plan section 2): actor, canonical, and duplicate through
    # base User ordered by id; then the selected case and its candidate row; then the
    # complete application inventory owned or managed by either participant. Every online
    # writer that must serialize with merge (portal submission/autosave, contact edits,
    # secure-request issuance) locks User rows through the same
    # +User.lock_for_merge_integrity!+ entry point, so this order can never deadlock against
    # a hardened writer.
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
      @locked_candidate_rows = @locked_case_candidate_rows.select do |candidate|
        candidate.duplicate_review_case_id == @duplicate_review_case.id
      end
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
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      GuardianRelationship.where(guardian_id: participant_ids)
                          .or(GuardianRelationship.where(dependent_id: participant_ids))
                          .pluck(:guardian_id, :dependent_id)
                          .flatten
                          .uniq
    end

    # Locks (without mutating) every application either participant owns or manages, so a
    # concurrent portal writer touching that inventory blocks until this transaction ends.
    def lock_application_inventory!
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      @locked_applications = Application.where(user_id: participant_ids)
                                        .or(Application.where(managing_guardian_id: participant_ids))
                                        .order(:id)
                                        .lock('FOR UPDATE')
                                        .load
    end

    # Every relationship whose endpoint can change is locked before the projection is
    # derived. Relationship creation also locks both User endpoints first, so no new edge
    # can be attached to either participant between this inventory read and retirement.
    def lock_guardian_relationship_inventory!
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      @locked_guardian_relationships = GuardianRelationship
                                       .where(guardian_id: participant_ids)
                                       .or(GuardianRelationship.where(dependent_id: participant_ids))
                                       .order(:id)
                                       .lock('FOR UPDATE')
                                       .load
      @guardian_relationship_plan = DuplicateMergeRelationshipPlan.new(
        canonical_user: @canonical_user,
        duplicate_user: @duplicate_user,
        relationships: @locked_guardian_relationships
      )
    end

    # Related case/relationship writers lock their User participants first. If one committed
    # between the advisory pre-scan and our User lock, the locked inventory can name a newly
    # discovered participant. Acquiring that missing User lock now could violate ascending lock
    # order, so fail closed and let a clean retry include the complete set from the start.
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

      raise MergeError, 'Related records changed while the merge was being prepared; reload and try again'
    end

    # A lock does not validate a stale decision (plan section 2): every authorization,
    # role, and pair fact used by static_preflight is re-derived against the freshly locked
    # rows, not the pre-lock instances the controller originally loaded.
    def post_lock_identity_recheck
      return 'An admin actor is required' unless admin_actor?
      return 'Only constituent records can be merged' unless both_constituents?

      pair_membership_error || canonical_eligibility_error || login_authority_error
    end

    # A retired identity retains no primary contact truth. Snapshotting happens before this
    # mutation, so the selected survivor values are already safe to apply to the canonical
    # row. Clearing every duplicate email/phone (not only values selected for transfer)
    # releases uniqueness ownership, prevents public registration from treating the retired
    # identity as an existing account, and invalidates password-reset tokens, whose purpose
    # fingerprint covers the normalized login email and phone.
    #
    # The same fingerprint is what revokes reset authority on the *canonical* survivor: this
    # merge may replace its phone (or its delivery route), and a reset link already emailed or
    # texted to a discarded contact must stop working. See +apply_canonical_contact!+ and
    # UserAuthentication's :password_reset token block.
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

    # FK-only repoint of the duplicate's owned applications, preserving each application's
    # lifecycle status, history, and audit trail. A person cannot manage their own
    # application, so if the canonical was the managing guardian of one of these apps,
    # clear the guardian first: update_all skips managing_guardian_cannot_be_applicant,
    # which would otherwise let a self-managed application persist silently. Scoped to the
    # ids from the already-requalified locked inventory, not a fresh re-query.
    def transfer_owned_applications!
      ids = selected_application_ids
      @summary[:applications_transferred] = ids.size
      return if ids.empty?

      owned = Application.where(id: ids)
      owned.where(managing_guardian_id: @canonical_user.id)
           .update_all(managing_guardian_id: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      owned.update_all(user_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Repoint applications the duplicate manages as guardian. Apps already owned by the
    # canonical would become self-managed, so drop the guardian on those instead of
    # pointing it back at the applicant. Scoped to ids from the locked inventory.
    def transfer_managed_applications!
      managed = @locked_applications.select { |app| app.managing_guardian_id == @duplicate_user.id }
      self_managed_ids = managed.select { |app| app.user_id == @canonical_user.id }.map(&:id)
      transferable_ids = managed.reject { |app| app.user_id == @canonical_user.id }.map(&:id)
      @summary[:managed_applications_transferred] = transferable_ids.size
      @summary[:managed_applications_guardian_cleared] = self_managed_ids.size

      Application.where(id: self_managed_ids).update_all(managing_guardian_id: nil, updated_at: Time.current) if self_managed_ids.any? # rubocop:disable Rails/SkipsModelValidations
      Application.where(id: transferable_ids).update_all(managing_guardian_id: @canonical_user.id, updated_at: Time.current) if transferable_ids.any? # rubocop:disable Rails/SkipsModelValidations
    end

    # A merge always transfers every application the duplicate owns. Partial transfer
    # would leave applications stranded on a retired record and could dodge the
    # active-application conflict check, so there is no selectable subset. Derived from the
    # locked inventory rather than a fresh query.
    def selected_application_ids
      @locked_applications.select { |app| app.user_id == @duplicate_user.id }.map(&:id)
    end

    def transfer_guardian_relationships!
      @summary.merge!(@guardian_relationship_plan.apply!)
    end

    # Same-person records that reference the duplicate directly (not through an
    # application) must follow the person to the canonical survivor only where that
    # doesn't rewrite history. Evaluations belong to an already-transferred application,
    # so they must move with it or evaluation.constituent would drift from
    # evaluation.application.user. Print queue items and notifications are historical
    # delivery/communication records ("Events / notifications / audit: Historical
    # records are preserved" per the merge inventory) and must not be repointed after
    # the fact -- except a still-pending print queue item, which is undelivered work
    # that needs an explicit, contactable owner going forward.
    def reconcile_person_references!
      @summary[:evaluations_transferred] =
        Evaluation.where(constituent_id: @duplicate_user.id)
                  .update_all(constituent_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      @summary[:pending_print_queue_items_transferred] =
        PrintQueueItem.where(constituent_id: @duplicate_user.id, status: :pending)
                      .update_all(constituent_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
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

    # The selected merge-eligible case records the identity decision. Other open exact-pair
    # post-import cases may be carried forward or superseded, but never receive a same/different
    # determination from this merge.
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
      SecureRequestForm.active.exists?(recipient_id: @duplicate_user.id)
    end

    # Derived from the locked inventory (lock_application_inventory!) rather than a fresh
    # query, so this decision reflects exactly the rows this transaction requalified.
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
