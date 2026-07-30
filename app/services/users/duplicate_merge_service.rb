# frozen_string_literal: true

module Users
  # Same-person merge of a duplicate constituent record into a canonical survivor.
  #
  # Contract:
  # - Requires an admin actor, an open *registration_soft_match* duplicate review case,
  #   explicit same-person confirmation, a rationale, evidence/reason codes, and explicit
  #   contact, delivery, and transfer choices.
  # - Locks the actor, both users, the case, its candidate row, and the complete
  #   application inventory (in that order); preflights every blocker against the
  #   requalified locked state; then performs all mutations with bang persistence inside a
  #   single transaction and rolls back on failure.
  # - Fails closed if any other open case references either participant, rather than
  #   repointing or auto-resolving it. Resolves only the selected case.
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

    CONTACT_SOURCES = %w[canonical duplicate].freeze

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
        audit_event = log_merge!
        resolve_selected_case!(audit_event)
        sync_canonical_review_flag!
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
      return 'Only a registration_soft_match case can be merged through this path' unless registration_soft_match_case?

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

    # PR4b's merge path exists to resolve an online-registration probable duplicate (plan
    # Goal/acceptance criteria); a staff-initiated support_claim/paper_intake/admin_create
    # case is out of this contract's scope.
    def registration_soft_match_case?
      @duplicate_review_case.registration_soft_match?
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

    # Each contact fact must be an explicit admin decision, not an inferred default:
    # a missing or garbage value must block the merge rather than silently resolve to
    # "canonical" and let the audit metadata misrepresent what the admin chose.
    def contact_choice_error
      %i[email phone address].each do |field|
        source = @contact_choices[field].to_s.presence
        return "An explicit #{field} choice (canonical or duplicate) is required" if source.blank?
        return "Invalid #{field} choice" unless CONTACT_SOURCES.include?(source)
      end
      nil
    end

    # The delivery route is chosen explicitly and independently from login identity
    # (see the merge inventory). A missing or invalid value must not silently fall
    # back to the canonical record's preference.
    def delivery_choice_error
      return 'An explicit delivery route choice (canonical or duplicate) is required' if @delivery_choice.blank?
      return 'Invalid delivery route choice' unless CONTACT_SOURCES.include?(@delivery_choice)

      nil
    end

    # Blockers that depend on live, locked state.
    def live_preflight
      return 'Case is no longer open' unless @duplicate_review_case.open?
      return duplicate_eligibility_error if duplicate_eligibility_error
      return 'The duplicate record has a pending recovery request; resolve it before merging' if duplicate_pending_recovery?
      return 'The duplicate record is the recipient of an active secure request form; revoke it before merging' if duplicate_active_secure_forms?
      return competing_case_message if competing_open_case?
      return application_conflict_message if application_conflict?
      return guardian_conflict_message if guardian_pair_conflict?

      contact_result_error
    end

    # Fail closed instead of reconciling every graph (plan section 3): any other open case
    # whose subject or candidate references either participant blocks the merge rather than
    # being silently repointed, coalesced, or auto-resolved alongside it.
    def competing_open_case?
      participant_ids = [@canonical_user.id, @duplicate_user.id]
      DuplicateReviewCase.open_cases
                         .where.not(id: @duplicate_review_case.id)
                         .exists?(['duplicate_review_cases.subject_user_id IN (?) OR EXISTS (' \
                                   'SELECT 1 FROM duplicate_review_case_candidates c ' \
                                   'WHERE c.duplicate_review_case_id = duplicate_review_cases.id ' \
                                   'AND c.candidate_user_id IN (?))', participant_ids, participant_ids])
    end

    def competing_case_message
      'Another open duplicate review case references one of these records; resolve it before merging'
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
      @contact_choices[:phone_type].to_s.presence
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
      locked_users = User.lock_for_merge_integrity!(@actor, @canonical_user, @duplicate_user)
      @actor = locked_users.fetch(@actor.id)
      @canonical_user = locked_users.fetch(@canonical_user.id)
      @duplicate_user = locked_users.fetch(@duplicate_user.id)

      @duplicate_review_case.lock!
      lock_candidate_row!
      lock_application_inventory!
    end

    def lock_candidate_row!
      @duplicate_review_case.duplicate_review_case_candidates
                            .where(candidate_user_id: [@canonical_user.id, @duplicate_user.id])
                            .lock('FOR UPDATE')
                            .load
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
    # identity as an existing account, and invalidates password-reset tokens whose purpose
    # fingerprint includes the normalized login email.
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
      dissolve_direct_pair_relationships!

      as_guardian = GuardianRelationship.where(guardian_id: @duplicate_user.id)
      as_dependent = GuardianRelationship.where(dependent_id: @duplicate_user.id)
      @summary[:guardian_relationships_transferred] = as_guardian.count + as_dependent.count

      # Pair conflicts are blocked in preflight and direct pair relationships are dissolved
      # above, so these repoints cannot violate the (guardian_id, dependent_id) uniqueness
      # or self-relationship constraints.
      as_guardian.update_all(guardian_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      as_dependent.update_all(dependent_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # A same-person merge dissolves any direct guardian relationship between the two
    # records; repointing it would produce a self-relationship (update_all skips the
    # guardian_and_dependent_must_be_different guard).
    def dissolve_direct_pair_relationships!
      pair = [@canonical_user.id, @duplicate_user.id]
      direct = GuardianRelationship.where(guardian_id: pair, dependent_id: pair)
      @summary[:guardian_relationships_dissolved] = direct.count
      direct.delete_all
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

    # The selected registration_soft_match case is the only case resolved by the merge
    # (plan section 3): this keeps the identity-transfer transaction's contract small and
    # leaves richer case routing -- and any other case touching either participant, which
    # competing_open_case? already blocked above -- out of it entirely.
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

    def sync_canonical_review_flag!
      remaining = DuplicateReviewCase.open_cases.for_subject(@canonical_user).exists?
      @canonical_user.update!(needs_duplicate_review: remaining)
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

    def guardian_pair_conflict?
      shared_dependent_conflict? || shared_guardian_conflict?
    end

    def shared_dependent_conflict?
      canonical_dependents = GuardianRelationship.where(guardian_id: @canonical_user.id).pluck(:dependent_id)
      duplicate_dependents = GuardianRelationship.where(guardian_id: @duplicate_user.id).pluck(:dependent_id)
      canonical_dependents.intersect?(duplicate_dependents)
    end

    def shared_guardian_conflict?
      canonical_guardians = GuardianRelationship.where(dependent_id: @canonical_user.id).pluck(:guardian_id)
      duplicate_guardians = GuardianRelationship.where(dependent_id: @duplicate_user.id).pluck(:guardian_id)
      canonical_guardians.intersect?(duplicate_guardians)
    end

    def guardian_conflict_message
      'Canonical and duplicate share a guardian/dependent relationship; resolve the relationship conflict before merging'
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
