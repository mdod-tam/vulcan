# frozen_string_literal: true

module Users
  # Same-person merge of a duplicate constituent record into a canonical survivor.
  #
  # Contract:
  # - Requires an admin actor, an actionable duplicate review case, explicit same-person
  #   confirmation, a rationale, evidence/reason codes, and explicit contact, delivery,
  #   and transfer choices.
  # - Locks both users and the case, preflights every blocker, then performs all
  #   mutations with bang persistence inside a single transaction and rolls back on failure.
  # - Retires (deactivates) the duplicate and points it at the canonical survivor; it is
  #   never destroyed. Clears review flags and resolves the related pending cases.
  # - Emits exactly one +duplicate_user_merged+ audit event.
  #
  # Concept boundaries preserved:
  # - Login identity: the canonical survivor keeps a real email if it was email-backed;
  #   synthetic/effective fallback values never become stored contact truth. After the
  #   selected values are captured, the retired duplicate releases its primary email and
  #   phone so global identity lookups and unique indexes do not treat discarded contact
  #   as a live owner.
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
        capture_final_contact!
        live_error = live_preflight
        raise MergeError, live_error if live_error

        release_duplicate_contact!
        apply_canonical_contact!
        transfer_applications!
        transfer_guardian_relationships!
        reconcile_person_references!
        reconcile_duplicate_review_candidate_references!
        expire_duplicate_sessions!
        retire_duplicate!
        audit_event = log_merge!
        resolve_related_cases!(audit_event)
        sync_canonical_review_flag!
      end

      success('Duplicate record merged', { canonical_user: @canonical_user, duplicate_user: @duplicate_user, summary: @summary })
    rescue MergeError => e
      failure(e.message)
    rescue ActiveRecord::RecordNotUnique
      failure('Pending duplicate-review work changed during the merge; reload and reconcile the cases before retrying')
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
      return 'Duplicate review case must be in an actionable review state' unless open_case?
      return 'Both canonical and duplicate users are required' if @canonical_user.blank? || @duplicate_user.blank?
      return 'Users must be persisted' unless @canonical_user.persisted? && @duplicate_user.persisted?
      return 'Canonical and duplicate users must be different' if @canonical_user.id == @duplicate_user.id
      return 'Only constituent records can be merged' unless both_constituents?
      return 'The review case subject must be one of the two records' unless subject_in_pair?
      return 'The other record must be a recorded candidate of this case' unless other_is_recorded_candidate?

      canonical_eligibility_error
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

    # The survivor must be a live, active record. Merging into a retired, inactive, or
    # suspended account would corrupt merge chains or apply contact to a dead record.
    def canonical_eligibility_error
      return 'The canonical survivor has already been merged into another record' if @canonical_user.merged?
      return 'The canonical survivor must be an active record (not inactive or suspended)' unless @canonical_user.public_login_active?

      nil
    end

    def intent_preflight
      return 'Same-person confirmation is required to merge' unless same_person_confirmed?
      return 'A rationale is required' if @rationale.blank?
      return 'At least one reason/evidence code is required' if @reason_codes.empty?

      'The duplicate record has already been merged' if @duplicate_user.merged?
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
      return 'Case is no longer in an actionable review state' unless @duplicate_review_case.merge_allowed?
      return 'The duplicate record has already been merged' if @duplicate_user.merged?
      return related_case_state_message if related_case_not_actionable?

      # Re-check under lock: static_preflight's canonical_eligibility_error ran on
      # whatever was loaded before the transaction, which a concurrent merge or
      # deactivation of the canonical could have since invalidated. lock_records! just
      # reloaded @canonical_user via SELECT ... FOR UPDATE, so this check is now
      # authoritative rather than a stale pre-lock snapshot.
      canonical_error = canonical_eligibility_error
      return canonical_error if canonical_error
      return 'The duplicate record has a pending recovery request; resolve it before merging' if duplicate_pending_recovery?
      return 'The duplicate record is the recipient of an active secure request form; revoke it before merging' if duplicate_active_secure_forms?
      return application_conflict_message if application_conflict?
      return guardian_conflict_message if guardian_pair_conflict?
      return candidate_deduplication_conflict_message if candidate_deduplication_conflict?

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

    def related_case_not_actionable?
      related_pending_cases.any? { |review_case| !review_case.merge_allowed? }
    end

    def related_case_state_message
      held_case = related_pending_cases.find { |review_case| !review_case.merge_allowed? }
      changed_message = "Duplicate review case ##{held_case.id} changed while the merge was being prepared; " \
                        'reload and review it before merging'
      return changed_message unless held_case.nonterminal_hold?

      "Duplicate review case ##{held_case.id} is #{held_case.status.humanize.downcase}; " \
        'return it to normal review before merging'
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

    def phone_type_invalid?
      return false if final_phone_type.blank?

      User.phone_types.key?(final_phone_type).equal?(false)
    end

    # --- Mutations -----------------------------------------------------------

    def lock_records!
      user_ids = [@canonical_user.id, @duplicate_user.id]
      locked_users = User.where(id: user_ids).order(:id).lock.index_by(&:id)
      raise MergeError, 'One of the selected users no longer exists' unless locked_users.size == user_ids.uniq.size

      @canonical_user = locked_users.fetch(@canonical_user.id)
      @duplicate_user = locked_users.fetch(@duplicate_user.id)
      candidate_cases = pending_candidate_reference_cases
      (related_pending_cases + candidate_cases).uniq.sort_by(&:id).each(&:lock!)

      # A resolution may have committed while merge waited for one of these case locks.
      # Requalify after lock! reloads each row; terminal cases are immutable history and
      # must never be repointed merely because they were pending during the first query.
      @pending_candidate_reference_cases = candidate_cases.select(&:pending?)
      pending_candidate_reference_rows
    end

    # The canonical record becomes the only live owner of primary identity contacts.
    # Capture happened before this method, so release both email and phone regardless of
    # which source was selected. Keeping an unselected value on the merged row would still
    # participate in global lookup, duplicate detection, and unique indexes.
    def release_duplicate_contact!
      mark_duplicate_retiring!
      @duplicate_user.update!(email: nil, phone: nil)
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
        communication_preference: final_communication_preference
      }
      attrs[:phone_type] = final_phone_type if final_phone.present? && final_phone_type.present?
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
    # which would otherwise let a self-managed application persist silently.
    def transfer_owned_applications!
      ids = selected_application_ids
      @summary[:applications_transferred] = ids.size
      return if ids.empty?

      owned = Application.where(id: ids, user_id: @duplicate_user.id)
      owned.where(managing_guardian_id: @canonical_user.id)
           .update_all(managing_guardian_id: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      owned.update_all(user_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # Repoint applications the duplicate manages as guardian. Apps already owned by the
    # canonical would become self-managed, so drop the guardian on those instead of
    # pointing it back at the applicant.
    def transfer_managed_applications!
      base = Application.where(managing_guardian_id: @duplicate_user.id)
      self_managed = base.where(user_id: @canonical_user.id)
      transferable = base.where.not(user_id: @canonical_user.id)
      @summary[:managed_applications_transferred] = transferable.count
      @summary[:managed_applications_guardian_cleared] = self_managed.count

      self_managed.update_all(managing_guardian_id: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      transferable.update_all(managing_guardian_id: @canonical_user.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end

    # A merge always transfers every application the duplicate owns. Partial transfer
    # would leave applications stranded on a retired record and could dodge the
    # active-application conflict check, so there is no selectable subset.
    def selected_application_ids
      @duplicate_user.applications.pluck(:id)
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

    # Pending cases about a third person remain actionable after this identity is
    # merged. Move their candidate link to the canonical survivor instead of leaving
    # the queue item pointed at a retired record. If that case already records the
    # canonical user for the same match reason, keep the existing row and remove the
    # now-redundant duplicate link.
    def reconcile_duplicate_review_candidate_references!
      transferred = 0
      deduplicated = 0
      affected_case_ids = pending_candidate_reference_rows.map(&:duplicate_review_case_id).uniq

      pending_candidate_reference_rows.each do |candidate_reference|
        existing = DuplicateReviewCaseCandidate.find_by(
          duplicate_review_case_id: candidate_reference.duplicate_review_case_id,
          candidate_user_id: @canonical_user.id,
          match_reason: candidate_reference.match_reason
        )

        if existing
          candidate_reference.destroy!
          deduplicated += 1
        else
          candidate_reference.update!(candidate_user: @canonical_user)
          transferred += 1
        end
      end

      recompute_candidate_deduplication_keys!(affected_case_ids)

      @summary[:duplicate_review_candidate_references_transferred] = transferred
      @summary[:duplicate_review_candidate_references_deduplicated] = deduplicated
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

    def resolve_related_cases!(audit_event)
      metadata = case_review_metadata(audit_event)
      now = Time.current
      related_pending_cases.each do |review_case|
        review_case.update!(
          status: :resolved_merged,
          review_rationale: @rationale,
          review_metadata: metadata,
          reviewed_by: @actor,
          reviewed_at: now,
          resolved_by: @actor,
          resolved_at: now
        )
      end
    end

    # Resolve everything that would otherwise leave the retired duplicate desynced:
    # every pending case whose subject is the duplicate (its identity no longer exists
    # independently), plus canonical-subject cases that name the duplicate as a candidate
    # (the same pair from the other side). A nonterminal related case blocks the merge
    # until staff explicitly return it to normal review. Canonical cases about unrelated
    # third parties stay pending and are reflected by sync_canonical_review_flag!.
    def related_pending_cases
      return @related_pending_cases if defined?(@related_pending_cases)

      cases = [@duplicate_review_case]
      cases += DuplicateReviewCase.pending_review.for_subject(@duplicate_user).to_a
      DuplicateReviewCase.pending_review
                         .for_subject(@canonical_user)
                         .find_each do |review_case|
        cases << review_case if references_duplicate?(review_case)
      end
      @related_pending_cases = cases.uniq
    end

    # These cases belong to an unrelated subject, so resolving them as part of this
    # merge would erase legitimate review work. They are locked with the merge and
    # their duplicate candidate links are repointed to the canonical survivor.
    def pending_candidate_reference_cases
      return @pending_candidate_reference_cases if defined?(@pending_candidate_reference_cases)

      case_ids = DuplicateReviewCaseCandidate
                 .joins(:duplicate_review_case)
                 .merge(DuplicateReviewCase.pending_review)
                 .where(candidate_user_id: @duplicate_user.id)
                 .distinct
                 .pluck(:duplicate_review_case_id)
      pair_ids = [@canonical_user.id, @duplicate_user.id]
      @pending_candidate_reference_cases = DuplicateReviewCase.where(id: case_ids).to_a.reject do |review_case|
        pair_ids.include?(review_case.subject_user_id)
      end
    end

    def pending_candidate_reference_rows
      return @pending_candidate_reference_rows if defined?(@pending_candidate_reference_rows)

      case_ids = pending_candidate_reference_cases.map(&:id)
      @pending_candidate_reference_rows = DuplicateReviewCaseCandidate
                                          .where(duplicate_review_case_id: case_ids, candidate_user_id: @duplicate_user.id)
                                          .order(:id)
                                          .lock
                                          .to_a
    end

    def candidate_deduplication_conflict?
      candidate_deduplication_conflict.present?
    end

    def candidate_deduplication_conflict_message
      conflict = candidate_deduplication_conflict
      return unless conflict

      "Repointing duplicate-review case ##{conflict.fetch(:affected_case_id)} would duplicate pending case " \
        "##{conflict.fetch(:existing_case_id)}; resolve one case before merging"
    end

    def candidate_deduplication_conflict
      return @candidate_deduplication_conflict if defined?(@candidate_deduplication_conflict)

      projected = {}
      affected_cases = pending_candidate_reference_cases
      affected_case_ids = affected_cases.map(&:id)
      @candidate_deduplication_conflict = affected_cases.each do |review_case|
        key = candidate_deduplication_key(review_case, projected: true)
        existing_id = projected[key] || DuplicateReviewCase.pending_review
                                                           .where(deduplication_key: key)
                                                           .where.not(id: affected_case_ids)
                                                           .pick(:id)
        break { affected_case_id: review_case.id, existing_case_id: existing_id } if existing_id

        projected[key] = review_case.id
      end
      @candidate_deduplication_conflict = nil unless @candidate_deduplication_conflict.is_a?(Hash)
      @candidate_deduplication_conflict
    end

    def recompute_candidate_deduplication_keys!(case_ids)
      pending_candidate_reference_cases.index_by(&:id).slice(*case_ids).each_value do |review_case|
        review_case.update!(deduplication_key: candidate_deduplication_key(review_case))
      end
    end

    def candidate_deduplication_key(review_case, projected: false)
      candidate_rows = review_case.duplicate_review_case_candidates.pluck(:candidate_user_id, :match_reason)
      if projected
        candidate_rows = candidate_rows.map do |candidate_user_id, match_reason|
          replacement_id = candidate_user_id == @duplicate_user.id ? @canonical_user.id : candidate_user_id
          [replacement_id, match_reason]
        end.uniq
      end

      DuplicateReviewCases::DeduplicationKey.call(
        source: review_case.source,
        subject_user_id: review_case.subject_user_id,
        reason_codes: review_case.metadata['reason_codes'],
        candidate_user_ids: candidate_rows.map(&:first)
      )
    end

    def references_duplicate?(review_case)
      review_case.duplicate_review_case_candidates
                 .pluck(:candidate_user_id).compact
                 .include?(@duplicate_user.id)
    end

    def case_review_metadata(audit_event)
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
      remaining = DuplicateReviewCase.pending_review.for_subject(@canonical_user).exists?
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
          review_outcome: 'same_person_confirmed',
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

    def application_conflict?
      canonical_blocking = @canonical_user.applications.blocking_new_submission.count
      transferred_blocking = @duplicate_user.applications
                                            .where(id: selected_application_ids)
                                            .blocking_new_submission.count
      (canonical_blocking + transferred_blocking) > 1
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
      @actor.respond_to?(:admin?) && @actor.admin?
    end

    def open_case?
      @duplicate_review_case.present? && @duplicate_review_case.merge_allowed?
    end

    def both_constituents?
      @canonical_user.is_a?(Users::Constituent) && @duplicate_user.is_a?(Users::Constituent)
    end

    def same_person_confirmed?
      ActiveModel::Type::Boolean.new.cast(@same_person_confirmed) == true
    end
  end
end
