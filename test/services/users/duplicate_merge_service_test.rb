# frozen_string_literal: true

require 'test_helper'

module Users
  class DuplicateMergeServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      @duplicate = phone_only_constituent(phone: '555-777-8888')
      @review_case = open_case(subject: @duplicate, candidate: @canonical, reason: 'exact_phone')
    end

    test 'merges a phone-only paper record into an email-backed portal account' do
      duplicate_app = create(:application, user: @duplicate)
      session = @duplicate.sessions.create!(session_token: SecureRandom.hex(16), user_agent: 'test', ip_address: '127.0.0.1')

      result = nil
      assert_difference 'Event.where(action: \'duplicate_user_merged\').count', 1 do
        result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      end

      assert result.success?, result.message

      @canonical.reload
      @duplicate.reload
      assert_equal '555-777-8888', @canonical.phone
      assert @canonical.real_phone?
      assert @canonical.real_email?, 'canonical keeps its portal email'
      assert_equal 'voice', @canonical.phone_type

      assert @duplicate.merged?
      assert_equal @canonical.id, @duplicate.merged_into_user_id
      assert_equal @admin.id, @duplicate.merged_by_id
      assert @duplicate.inactive?
      assert_not @duplicate.needs_duplicate_review
      assert_nil @duplicate.phone, 'duplicate releases the moved phone'

      assert_equal @canonical.id, duplicate_app.reload.user_id
      assert_not Session.exists?(session.id), 'duplicate session expired'

      @review_case.reload
      assert_equal 'resolved_merged', @review_case.status
      assert_equal 'confirmed same person via support call', @review_case.review_rationale
      assert_equal @admin, @review_case.reviewed_by
    end

    test 'blocks merge without same-person confirmation' do
      result = merge(same_person_confirmed: false)
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge while the selected case is in a nonterminal workflow state' do
      @review_case.update!(
        status: :awaiting_information,
        review_rationale: 'Waiting for records.',
        reviewed_by: @admin,
        reviewed_at: Time.current
      )

      result = merge

      assert result.failure?
      assert_match(/actionable review state/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge while a related case is under security review' do
      related_case = open_case(subject: @duplicate, candidate: create(:constituent), reason: 'name_dob')
      related_case.update!(
        status: :security_review,
        review_rationale: 'Security specialist review.',
        reviewed_by: @admin,
        reviewed_at: Time.current
      )

      result = merge

      assert result.failure?
      assert_match(/security review.*return it to normal review/i, result.message)
      assert_not @duplicate.reload.merged?
      assert related_case.reload.security_review?
    end

    test 'blocks merge for a non-admin actor' do
      result = merge(actor: create(:constituent))
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the duplicate has a pending recovery request' do
      @duplicate.recovery_requests.create!(status: 'pending', ip_address: '127.0.0.1', user_agent: 'test')
      result = merge
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the duplicate is recipient of an active secure request form' do
      application = create(:application, user: @duplicate)
      create(:secure_request_form, application: application, recipient: @duplicate)
      result = merge
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge that would create conflicting active applications' do
      create(:application, user: @canonical, status: :in_progress)
      create(:application, user: @duplicate, status: :in_progress)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge on shared guardian relationship conflict' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: dependent)
      create(:guardian_relationship, guardian_user: @duplicate, dependent_user: dependent)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'merges taking the duplicate email with a phone-only subject as canonical' do
      phone_only_subject = phone_only_constituent(phone: '555-222-3333')
      email_backed = create(:constituent, email: "portal2-#{SecureRandom.hex(3)}@example.com")
      surviving_email = email_backed.email
      review_case = open_case(subject: phone_only_subject, candidate: email_backed, reason: 'exact_phone')

      result = DuplicateMergeService.new(
        actor: @admin,
        duplicate_review_case: review_case,
        canonical_user: phone_only_subject,
        duplicate_user: email_backed,
        same_person_confirmed: true,
        rationale: 'same person confirmed via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { email: 'duplicate', phone: 'canonical', phone_type: 'voice', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call

      assert result.success?, result.message
      phone_only_subject.reload
      email_backed.reload
      assert phone_only_subject.real_email?, 'canonical took the email-backed email'
      assert_equal surviving_email, phone_only_subject.email
      assert email_backed.merged?
      assert_nil email_backed.email, 'the retired email-backed duplicate released its email'
    end

    test 'releases discarded duplicate email and phone when canonical contact survives' do
      canonical_email = @canonical.email
      canonical_phone = '555-111-2222'
      discarded_email = "retired-#{SecureRandom.hex(3)}@example.com"
      discarded_phone = @duplicate.phone
      @canonical.update!(phone: canonical_phone, phone_type: :voice)
      @duplicate.update!(email: discarded_email)

      result = merge(
        contact_choices: { email: 'canonical', phone: 'canonical', phone_type: 'voice', address: 'canonical' }
      )

      assert result.success?, result.message
      assert_equal canonical_email, @canonical.reload.email
      assert_equal canonical_phone, @canonical.phone
      assert_nil @duplicate.reload.email
      assert_nil @duplicate.phone
      assert_nil User.find_by_email(discarded_email), 'retired email must not remain a global identity owner'
      assert_nil User.find_by_phone(discarded_phone), 'retired phone must not remain a global identity owner'
    end

    test 'invalidates an outstanding canonical password reset token when merge replaces its email' do
      replacement_email = "replacement-#{SecureRandom.hex(3)}@example.com"
      @duplicate.update!(email: replacement_email)
      token = @canonical.generate_token_for(:password_reset)
      assert_equal @canonical, User.find_by_token_for(:password_reset, token)

      result = merge(
        contact_choices: { email: 'duplicate', phone: 'duplicate', phone_type: 'voice', address: 'canonical' }
      )

      assert result.success?, result.message
      assert_equal replacement_email, @canonical.reload.email
      assert_nil User.find_by_token_for(:password_reset, token)
    end

    test 'preserves canonical and retired duplicate MFA credential ownership' do
      create(:webauthn_credential, user: @canonical)
      create(:webauthn_credential, user: @duplicate)
      @canonical.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Canonical authenticator')
      @duplicate.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Duplicate authenticator')
      @canonical.sms_credentials.create!(phone_number: '410-555-0101', verified_at: Time.current)
      @duplicate.sms_credentials.create!(phone_number: '410-555-0102', verified_at: Time.current)
      canonical_credentials = mfa_credential_snapshot(@canonical)
      duplicate_credentials = mfa_credential_snapshot(@duplicate)

      result = merge

      assert result.success?, result.message
      assert_equal canonical_credentials, mfa_credential_snapshot(@canonical.reload)
      assert_equal duplicate_credentials, mfa_credential_snapshot(@duplicate.reload)
    end

    test 'rolls back the full merge inventory when a late transaction step fails' do
      duplicate_application = create(:application, user: @duplicate)
      dependent = create(:constituent)
      relationship = create(:guardian_relationship, guardian_user: @duplicate, dependent_user: dependent)
      duplicate_session = @duplicate.sessions.create!(
        session_token: SecureRandom.hex(16),
        user_agent: 'rollback test',
        ip_address: '127.0.0.1'
      )
      canonical_contact = @canonical.attributes.slice('email', 'phone', 'status', 'merged_into_user_id')
      duplicate_contact = @duplicate.attributes.slice('email', 'phone', 'status', 'merged_into_user_id')
      service = build_service
      service.define_singleton_method(:log_merge!) do
        raise ActiveRecord::RecordInvalid, Event.new
      end

      result = nil
      assert_no_difference "Event.where(action: 'duplicate_user_merged').count" do
        result = service.call
      end

      assert result.failure?
      assert_equal canonical_contact, @canonical.reload.attributes.slice(*canonical_contact.keys)
      assert_equal duplicate_contact, @duplicate.reload.attributes.slice(*duplicate_contact.keys)
      assert_equal @duplicate.id, duplicate_application.reload.user_id
      assert_equal @duplicate.id, relationship.reload.guardian_id
      assert Session.exists?(duplicate_session.id), 'destroyed session must return on rollback'
      assert @review_case.reload.open?
    end

    test 'blocks merge when the canonical survivor is already merged' do
      other = create(:constituent)
      @canonical.update!(merged_into_user: other, merged_at: Time.current)
      result = merge
      assert result.failure?
      assert_match(/already been merged/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the canonical survivor is inactive' do
      @canonical.update!(status: :inactive)
      result = merge
      assert result.failure?
      assert_match(/active record/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the canonical becomes ineligible between static preflight and the lock' do
      service = build_service
      other_canonical = create(:constituent)

      # Simulate a concurrent merge/deactivation of the canonical landing exactly between
      # static_preflight (which passed on the then-eligible canonical) and lock_records!
      # taking the row lock -- live_preflight's post-lock recheck must still catch it.
      service.define_singleton_method(:lock_records!) do
        User.where(id: @canonical_user.id).update_all(
          merged_into_user_id: other_canonical.id, status: User.statuses[:inactive], updated_at: Time.current
        )
        super()
      end

      result = service.call
      assert result.failure?
      assert_match(/canonical survivor/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the pair does not include the case subject' do
      other_candidate = create(:constituent, email: "other-#{SecureRandom.hex(3)}@example.com")
      @review_case.duplicate_review_case_candidates.create!(candidate_user: other_candidate, match_reason: 'name_dob', snapshot: {})
      # @canonical and other_candidate are both candidates, but the subject (@duplicate) is absent.
      result = merge(canonical_user: @canonical, duplicate_user: other_candidate)
      assert result.failure?
      assert_match(/subject must be one of the two records/i, result.message)
      assert_not other_candidate.reload.merged?
    end

    test 'blocks stranding an email-backed portal account without a real email' do
      duplicate_without_email = @duplicate # phone-only, no real email
      result = merge(
        duplicate_user: duplicate_without_email,
        contact_choices: { email: 'duplicate', phone: 'duplicate', phone_type: 'voice', address: 'canonical' }
      )
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'requires an explicit phone type when a real phone survives' do
      result = merge(contact_choices: { phone: 'duplicate', email: 'canonical', address: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when a contact choice is missing' do
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', address: 'canonical' })
      assert result.failure?
      assert_match(/explicit email choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when a contact choice is invalid' do
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'nonsense', address: 'canonical' })
      assert result.failure?
      assert_match(/invalid email choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the delivery choice is missing' do
      result = merge(delivery_choice: nil)
      assert result.failure?
      assert_match(/explicit delivery route choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the delivery choice is invalid' do
      result = merge(delivery_choice: 'nonsense')
      assert result.failure?
      assert_match(/invalid delivery route choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'resolves the retired duplicate other pending cases and keeps unrelated canonical cases pending' do
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")
      duplicate_other_case = open_case(subject: @duplicate, candidate: third_party, reason: 'name_dob')
      canonical_unrelated = open_case(subject: @canonical, candidate: third_party, reason: 'name_dob')

      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.success?, result.message

      assert_equal 'resolved_merged', duplicate_other_case.reload.status
      assert_equal 'open', canonical_unrelated.reload.status, 'unrelated canonical case stays open'
      assert DuplicateReviewCase.pending_review.for_subject(@duplicate).none?, 'retired duplicate has no pending cases'
      assert @canonical.reload.needs_duplicate_review, 'canonical flag reflects its remaining open case'
    end

    test 'repoints and deduplicates unrelated pending candidate references to the canonical survivor' do
      first_subject = create(:constituent, needs_duplicate_review: true)
      repointed_case = open_case(subject: first_subject, candidate: @duplicate, reason: 'name_dob')

      second_subject = create(:constituent, needs_duplicate_review: true)
      deduplicated_case = open_case(subject: second_subject, candidate: @duplicate, reason: 'exact_phone')
      deduplicated_case.duplicate_review_case_candidates.create!(
        candidate_user: @canonical,
        match_reason: 'exact_phone',
        snapshot: {}
      )

      result = merge
      assert result.success?, result.message

      [repointed_case, deduplicated_case].each do |review_case|
        assert review_case.reload.open?, 'unrelated-subject review work must remain pending'
        assert_not review_case.duplicate_review_case_candidates.exists?(candidate_user_id: @duplicate.id)
        assert review_case.duplicate_review_case_candidates.exists?(candidate_user_id: @canonical.id)
      end
      assert_equal 1, repointed_case.duplicate_review_case_candidates.where(candidate_user_id: @canonical.id).count
      assert_equal 1, deduplicated_case.duplicate_review_case_candidates.where(candidate_user_id: @canonical.id).count
      assert first_subject.reload.needs_duplicate_review
      assert second_subject.reload.needs_duplicate_review
      assert_equal 1, result.data[:summary][:duplicate_review_candidate_references_transferred]
      assert_equal 1, result.data[:summary][:duplicate_review_candidate_references_deduplicated]
    end

    test 'does not emit profile audit events during a successful merge' do
      profile_actions = %w[profile_updated profile_updated_by_guardian profile_created_by_admin_via_paper]
      result = nil
      assert_no_difference -> { Event.where(action: profile_actions).count } do
        result = merge
      end
      assert result.success?, result.message
      assert_equal 1, Event.where(action: 'duplicate_user_merged').count
    end

    test 'does not deduplicate audit events across two rapid merges into the same canonical' do
      result_one = merge
      assert result_one.success?, result_one.message

      second_duplicate = phone_only_constituent(phone: '555-999-1111')
      second_case = open_case(subject: second_duplicate, candidate: @canonical, reason: 'exact_phone')

      result_two = nil
      assert_difference 'Event.where(action: \'duplicate_user_merged\').count', 1 do
        result_two = merge(
          duplicate_review_case: second_case,
          duplicate_user: second_duplicate,
          contact_choices: { phone: 'canonical', phone_type: 'voice', email: 'canonical', address: 'canonical' }
        )
      end
      assert result_two.success?, result_two.message

      merged_ids = Event.where(action: 'duplicate_user_merged').pluck(Arel.sql("metadata->>'merged_user_id'"))
      assert_equal [@duplicate.id.to_s, second_duplicate.id.to_s].sort, merged_ids.sort,
                   'both merges into the same canonical must each keep their own audit event'
    end

    test 'clears the managing guardian when a transferred app was managed by the canonical' do
      app = create(:application, user: @duplicate, managing_guardian: @canonical)
      result = merge
      assert result.success?, result.message

      app.reload
      assert_equal @canonical.id, app.user_id
      assert_nil app.managing_guardian_id, 'a merged self-application must not be self-managed'
      assert app.valid?, "transferred app must stay valid: #{app.errors.full_messages.to_sentence}"
    end

    test 'clears the managing guardian when the canonical already owns an app managed by the duplicate' do
      app = create(:application, user: @canonical, managing_guardian: @duplicate)
      result = merge
      assert result.success?, result.message

      app.reload
      assert_equal @canonical.id, app.user_id
      assert_nil app.managing_guardian_id, 'guardian dropped instead of self-referencing the canonical'
      assert app.valid?, "managed app must stay valid: #{app.errors.full_messages.to_sentence}"
    end

    test 'dissolves a direct guardian relationship between the merged pair' do
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: @duplicate)
      result = merge
      assert result.success?, result.message

      assert_equal 0, GuardianRelationship.where(guardian_id: @canonical.id, dependent_id: @canonical.id).count,
                   'must not create a self guardian relationship'
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
      assert_not GuardianRelationship.exists?(guardian_id: @duplicate.id)
    end

    test 'transfers evaluations and pending print queue items but preserves historical records' do
      duplicate_app = create(:application, user: @duplicate)
      evaluation = create(:evaluation, constituent: @duplicate, application: duplicate_app)
      pending_print_item = create(:print_queue_item, :pending, constituent: @duplicate)
      printed_item = create(:print_queue_item, constituent: @duplicate)
      canceled_item = create(:print_queue_item, :canceled, constituent: @duplicate)
      notification = create(:notification, recipient: @duplicate)

      result = merge
      assert result.success?, result.message

      assert_equal @canonical.id, evaluation.reload.constituent_id,
                   'evaluation must follow the person to stay consistent with its already-transferred application'
      assert_equal @canonical.id, pending_print_item.reload.constituent_id,
                   'a still-pending print queue item needs an explicit, contactable owner'
      assert_equal @duplicate.id, printed_item.reload.constituent_id, 'a printed letter is historical and must not be rewritten'
      assert_equal @duplicate.id, canceled_item.reload.constituent_id, 'a canceled letter is historical and must not be rewritten'
      assert_equal @duplicate.id, notification.reload.recipient_id, 'notification history is preserved, not repointed'
    end

    test 'transfers guardian-as-dependent relationships without copying guardian contact' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @duplicate)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.success?, result.message
      assert GuardianRelationship.exists?(guardian_id: guardian.id, dependent_id: @canonical.id)
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
    end

    private

    def merge(**overrides)
      build_service(**overrides).call
    end

    def build_service(**overrides)
      defaults = {
        actor: @admin,
        duplicate_review_case: @review_case,
        canonical_user: @canonical,
        duplicate_user: @duplicate,
        same_person_confirmed: true,
        rationale: 'confirmed same person via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical'
      }
      DuplicateMergeService.new(**defaults, **overrides)
    end

    def phone_only_constituent(phone:)
      Current.paper_context = true
      create(:constituent, email: nil, phone: phone, communication_preference: :letter)
    ensure
      Current.reset
    end

    def open_case(subject:, candidate:, reason:)
      review_case = DuplicateReviewCase.create!(
        source: :support_claim,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => [reason] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: candidate, match_reason: reason, snapshot: {})
      review_case
    end

    def mfa_credential_snapshot(user)
      {
        webauthn: user.webauthn_credentials.order(:id).map do |credential|
          credential.attributes.slice('id', 'user_id', 'external_id', 'public_key', 'nickname', 'sign_count')
        end,
        totp: user.totp_credentials.order(:id).map do |credential|
          credential.attributes.slice('id', 'user_id', 'secret', 'nickname', 'last_used_at')
        end,
        sms: user.sms_credentials.order(:id).map do |credential|
          credential.attributes.slice('id', 'user_id', 'phone_number', 'last_sent_at', 'verified_at')
        end
      }
    end
  end
end
