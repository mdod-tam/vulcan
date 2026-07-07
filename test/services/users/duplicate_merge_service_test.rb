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
      assert_equal 'same_person_confirmed', @review_case.resolution_determination
    end

    test 'blocks merge without same-person confirmation' do
      result = merge(same_person_confirmed: false)
      assert result.failure?
      assert_not @duplicate.reload.merged?
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
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge on shared guardian relationship conflict' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: dependent)
      create(:guardian_relationship, guardian_user: @duplicate, dependent_user: dependent)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice' })
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
        contact_choices: { email: 'duplicate', phone: 'duplicate', phone_type: 'voice' }
      )
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'requires an explicit phone type when a real phone survives' do
      result = merge(contact_choices: { phone: 'duplicate', email: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'resolves the retired duplicate other open cases and keeps unrelated canonical cases open' do
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")
      duplicate_other_case = open_case(subject: @duplicate, candidate: third_party, reason: 'name_dob')
      canonical_unrelated = open_case(subject: @canonical, candidate: third_party, reason: 'name_dob')

      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.success?, result.message

      assert_equal 'resolved_merged', duplicate_other_case.reload.status
      assert_equal 'open', canonical_unrelated.reload.status, 'unrelated canonical case stays open'
      assert DuplicateReviewCase.open_cases.for_subject(@duplicate).none?, 'retired duplicate has no open cases'
      assert @canonical.reload.needs_duplicate_review, 'canonical flag reflects its remaining open case'
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

    test 'transfers guardian-as-dependent relationships without copying guardian contact' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @duplicate)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice' })
      assert result.success?, result.message
      assert GuardianRelationship.exists?(guardian_id: guardian.id, dependent_id: @canonical.id)
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
    end

    private

    def merge(**overrides)
      defaults = {
        actor: @admin,
        duplicate_review_case: @review_case,
        canonical_user: @canonical,
        duplicate_user: @duplicate,
        same_person_confirmed: true,
        rationale: 'confirmed same person via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical',
        transfer_choices: {}
      }
      DuplicateMergeService.new(**defaults, **overrides).call
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
  end
end
