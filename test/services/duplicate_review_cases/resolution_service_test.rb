# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ResolutionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: true)
      @candidate = create(:constituent)
      @review_case = open_case_for(@subject, candidate: @candidate)
    end

    test 'needs more information keeps the case pending and changes no user-owned data' do
      snapshot = build_and_snapshot_user_owned_data

      assert_difference "Event.where(action: 'duplicate_review_case_awaiting_information').count", 1 do
        result = resolve(outcome: 'needs_more_information', rationale: 'Waiting for identity documents.')
        assert result.success?, result.message
      end

      @review_case.reload
      assert @review_case.awaiting_information?
      assert @review_case.pending?
      assert @review_case.owns_duplicate_review_flag?
      assert_not @review_case.merge_allowed?
      assert_equal @admin, @review_case.reviewed_by
      assert @review_case.reviewed_at.present?
      assert_equal 'Waiting for identity documents.', @review_case.review_rationale
      assert_nil @review_case.resolved_at
      assert @subject.reload.needs_duplicate_review
      event = Event.where(action: 'duplicate_review_case_awaiting_information').last
      assert_equal @admin, event.user
      assert_equal @review_case.id, event.metadata['duplicate_review_case_id']
      assert_equal 'Waiting for identity documents.', event.metadata['rationale']
      assert event.created_at.present?
      assert_user_owned_data_unchanged(snapshot)
    end

    test 'security review keeps the case pending without suspending or changing user-owned data' do
      snapshot = build_and_snapshot_user_owned_data

      assert_difference "Event.where(action: 'duplicate_review_case_security_review_started').count", 1 do
        result = resolve(outcome: 'fraud_or_security_review', rationale: 'Specialist review requested.')
        assert result.success?, result.message
      end

      @review_case.reload
      assert @review_case.security_review?
      assert @review_case.pending?
      assert_not @review_case.merge_allowed?
      assert @subject.reload.needs_duplicate_review
      assert @subject.active?, 'security review must not suspend or deactivate the account'
      event = Event.where(action: 'duplicate_review_case_security_review_started').last
      assert_equal @admin, event.user
      assert_equal @review_case.id, event.metadata['duplicate_review_case_id']
      assert_equal 'Specialist review requested.', event.metadata['rationale']
      assert event.created_at.present?
      assert_user_owned_data_unchanged(snapshot)
    end

    test 'keep separate resolves terminally and clears the flag when no pending case remains' do
      snapshot = build_and_snapshot_user_owned_data

      result = resolve(outcome: 'keep_separate', rationale: 'Verified as different people.')

      assert result.success?, result.message
      @review_case.reload
      assert @review_case.resolved_keep_separate?
      assert @review_case.terminal?
      assert_equal @admin, @review_case.resolved_by
      assert @review_case.resolved_at.present?
      assert_not @subject.reload.needs_duplicate_review
      assert_user_owned_data_unchanged(snapshot)
    end

    test 'keep separate leaves the flag set while another nonterminal case remains' do
      pending_case = open_case_for(@subject, candidate: create(:constituent))
      pending_result = resolve_case(pending_case, outcome: 'needs_more_information', rationale: 'Waiting on records.')
      assert pending_result.success?, pending_result.message

      result = resolve(outcome: 'keep_separate')

      assert result.success?, result.message
      assert @subject.reload.needs_duplicate_review
      assert pending_case.reload.awaiting_information?
    end

    test 'same person confirmation remains merge only' do
      result = resolve(outcome: 'same_person_confirmed')

      assert result.failure?
      assert_match(/requires a merge/i, result.message)
      assert @review_case.reload.open?
      assert @subject.reload.needs_duplicate_review
    end

    test 'authorized relationship cannot resolve until a supported relationship is persisted' do
      result = resolve(outcome: 'authorized_relationship_confirmed')

      assert result.failure?
      assert_match(/create the supported guardian or authorized relationship/i, result.message)
      assert @review_case.reload.open?
      assert @subject.reload.needs_duplicate_review
    end

    test 'authorized relationship resolves after the relationship is persisted without merging' do
      relationship = create(:guardian_relationship, guardian_user: @subject, dependent_user: @candidate)

      result = resolve(outcome: 'authorized_relationship_confirmed')

      assert result.success?, result.message
      assert @review_case.reload.resolved_relationship?
      assert GuardianRelationship.exists?(relationship.id)
      assert_not @subject.reload.merged?
      assert_not @candidate.reload.merged?
    end

    test 'rejects blank, unsupported, and forged outcomes server side' do
      [nil, '', 'resolved_merged', 'open', 'totally_forged'].each do |outcome|
        result = resolve(outcome: outcome)
        assert result.failure?, "expected #{outcome.inspect} to fail"
        assert @review_case.reload.open?
      end
    end

    test 'requires an admin actor and nonblank rationale' do
      non_admin_result = ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: create(:constituent),
        outcome: 'keep_separate',
        rationale: 'Reviewed.'
      ).call
      blank_rationale_result = resolve(outcome: 'keep_separate', rationale: '  ')

      assert non_admin_result.failure?
      assert blank_rationale_result.failure?
      assert @review_case.reload.open?
    end

    test 'case update, flag sync, and audit event roll back together' do
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      result = resolve(outcome: 'keep_separate')

      assert result.failure?
      assert @review_case.reload.open?
      assert @subject.reload.needs_duplicate_review
    end

    test 'rapid repeated nonterminal transitions retain distinct audit events' do
      first = resolve(outcome: 'needs_more_information', rationale: 'First request for information.')
      assert first.success?, first.message
      resumed = ResumeService.new(
        duplicate_review_case: @review_case,
        actor: @admin,
        rationale: 'Initial response arrived.'
      ).call
      assert resumed.success?, resumed.message

      assert_difference "Event.where(action: 'duplicate_review_case_awaiting_information').count", 1 do
        second = resolve(outcome: 'needs_more_information', rationale: 'A second document is still needed.')
        assert second.success?, second.message
      end

      events = Event.where(action: 'duplicate_review_case_awaiting_information').order(:created_at)
      assert_equal 2, events.count
      assert_equal(
        ['First request for information.', 'A second document is still needed.'],
        events.map { |event| event.metadata['rationale'] }
      )
    end

    test 'address-only paper constituent remains valid and truthful while review is pending' do
      address_only = nil
      Current.paper_context = true
      begin
        address_only = Users::Constituent.create!(
          first_name: 'Address',
          last_name: 'Only',
          email: nil,
          phone: nil,
          phone_type: :contact_letter,
          communication_preference: :letter,
          physical_address_1: '123 Main Street',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          date_of_birth: Date.new(1950, 1, 1),
          password: 'password123',
          password_confirmation: 'password123',
          hearing_disability: true,
          needs_duplicate_review: true
        )
      ensure
        Current.reset
      end
      address_case = open_case_for(address_only, candidate: create(:constituent))

      result = resolve_case(address_case, outcome: 'needs_more_information', rationale: 'Waiting for paper records.')

      assert result.success?, result.message
      address_only.reload
      assert address_only.valid?
      assert_nil address_only.email
      assert_nil address_only.phone
      assert address_only.address_only_contact?
      assert address_only.needs_duplicate_review
    end

    private

    def resolve(outcome:, rationale: 'Reviewed and documented.')
      resolve_case(@review_case, outcome: outcome, rationale: rationale)
    end

    def resolve_case(review_case, outcome:, rationale:)
      ResolutionService.new(
        duplicate_review_case: review_case,
        actor: @admin,
        outcome: outcome,
        rationale: rationale,
        reason_codes: %w[name_dob]
      ).call
    end

    def open_case_for(user, candidate:)
      review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: user,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(
        candidate_user: candidate,
        match_reason: 'name_dob',
        snapshot: {}
      )
      review_case
    end

    def build_and_snapshot_user_owned_data
      dependent = create(:constituent)
      create(:application, user: @subject)
      create(:guardian_relationship, guardian_user: @subject, dependent_user: dependent)
      create(:webauthn_credential, user: @subject)
      @subject.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Test authenticator')
      @subject.sms_credentials.create!(phone_number: '410-555-0123', verified_at: Time.current)
      @subject.sessions.create!(session_token: SecureRandom.hex(16), user_agent: 'test', ip_address: '127.0.0.1')
      @subject.reload
      relationships = GuardianRelationship
                      .where('guardian_id = :id OR dependent_id = :id', id: @subject.id)
                      .order(:id).pluck(:id, :guardian_id, :dependent_id, :relationship_type)

      {
        contacts: [@subject.email, @subject.phone, @subject.physical_address_1, @subject.city, @subject.state, @subject.zip_code],
        applications: @subject.applications.order(:id).pluck(:id, :user_id, :status),
        relationships: relationships,
        credential_ids: {
          webauthn: @subject.webauthn_credentials.order(:id).ids,
          totp: @subject.totp_credentials.order(:id).ids,
          sms: @subject.sms_credentials.order(:id).ids
        },
        session_ids: @subject.sessions.order(:id).ids,
        communication_preference: @subject.communication_preference,
        status: @subject.status,
        password_digest: @subject.password_digest
      }
    end

    def assert_user_owned_data_unchanged(snapshot)
      @subject.reload
      assert_equal snapshot[:contacts],
                   [@subject.email, @subject.phone, @subject.physical_address_1, @subject.city, @subject.state, @subject.zip_code]
      assert_equal snapshot[:applications], @subject.applications.order(:id).pluck(:id, :user_id, :status)
      assert_equal snapshot[:relationships],
                   GuardianRelationship.where('guardian_id = :id OR dependent_id = :id', id: @subject.id)
                                       .order(:id).pluck(:id, :guardian_id, :dependent_id, :relationship_type)
      assert_equal snapshot[:credential_ids], {
        webauthn: @subject.webauthn_credentials.order(:id).ids,
        totp: @subject.totp_credentials.order(:id).ids,
        sms: @subject.sms_credentials.order(:id).ids
      }
      assert_equal snapshot[:session_ids], @subject.sessions.order(:id).ids
      assert_equal snapshot[:communication_preference], @subject.communication_preference
      assert_equal snapshot[:status], @subject.status
      assert_equal snapshot[:password_digest], @subject.password_digest
    end
  end
end
