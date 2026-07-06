# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class CreateServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: false)
      @candidate = create(:constituent, email: "candidate-#{SecureRandom.hex(3)}@example.com")
    end

    test 'creates open case with candidates and syncs review flag' do
      assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
        assert_changes -> { @subject.reload.needs_duplicate_review }, from: false, to: true do
          result = create_case
          assert result.success?
          assert result.data[:duplicate_review_case].open?
        end
      end

      duplicate_case = DuplicateReviewCase.last
      assert_equal 'registration_soft_match', duplicate_case.source
      assert_includes duplicate_case.metadata['reason_codes'], 'name_dob'
      assert_equal 1, duplicate_case.duplicate_review_case_candidates.count
    end

    test 'idempotent create returns existing open case without duplicate audit' do
      first = create_case
      assert first.success?

      assert_no_difference ['DuplicateReviewCase.count', 'Event.count'] do
        second = create_case
        assert second.success?
        assert second.data[:idempotent]
        assert_equal first.data[:duplicate_review_case].id, second.data[:duplicate_review_case].id
      end
    end

    test 'subject deletion preserves duplicate review case for staff history' do
      result = create_case
      assert result.success?
      duplicate_case = result.data[:duplicate_review_case]

      assert_no_difference 'DuplicateReviewCase.count' do
        @subject.destroy!
      end

      assert_nil duplicate_case.reload.subject_user_id
    end

    test 'requires subject user and actor' do
      assert_no_workflow_side_effects do
        result = CreateService.new(
          source: :registration_soft_match,
          subject_user: nil,
          actor: @admin,
          reason_codes: ['name_dob'],
          candidates: []
        ).call

        assert result.failure?
      end

      assert_no_workflow_side_effects do
        result = CreateService.new(
          source: :registration_soft_match,
          subject_user: @subject,
          actor: nil,
          reason_codes: ['name_dob'],
          candidates: []
        ).call

        assert result.failure?
      end
    end

    test 'rejects unpersisted subject without workflow side effects' do
      unpersisted = Users::Constituent.new(
        first_name: 'Unsaved',
        last_name: 'Subject',
        email: "unsaved-#{SecureRandom.hex(3)}@example.com",
        password: 'password123',
        password_confirmation: 'password123',
        date_of_birth: Date.new(1990, 1, 1),
        hearing_disability: true
      )

      assert_no_workflow_side_effects do
        result = CreateService.new(
          source: :registration_soft_match,
          subject_user: unpersisted,
          actor: @admin,
          reason_codes: ['name_dob'],
          candidates: []
        ).call

        assert result.failure?
      end
    end

    test 'failed preconditions create no case candidates audit or review flag' do
      assert_no_workflow_side_effects do
        CreateService.new(
          source: :registration_soft_match,
          subject_user: nil,
          actor: @admin,
          reason_codes: ['name_dob'],
          candidates: [CreateService::CandidateInput.new(user: @candidate, match_reason: 'name_dob')]
        ).call
      end
    end

    test 'drops raw contact values from candidate snapshots' do
      result = CreateService.new(
        source: :registration_soft_match,
        subject_user: @subject,
        actor: @admin,
        reason_codes: ['name_dob'],
        candidates: [
          CreateService::CandidateInput.new(
            user: @candidate,
            match_reason: 'name_dob',
            snapshot: {
              contact_digest: 'secret@example.com',
              last_four: '4105550198',
              real_email: true
            }
          )
        ],
        metadata: { intake_context: 'registration' }
      ).call

      assert result.success?
      candidate = result.data[:duplicate_review_case].duplicate_review_case_candidates.first
      assert_equal true, candidate.snapshot['real_email']
      assert_not candidate.snapshot.key?('contact_digest')
      assert_not candidate.snapshot.key?('last_four')
    end

    test 'persists email_phone_split metadata reason codes' do
      result = CreateService.new(
        source: :registration_soft_match,
        subject_user: @subject,
        actor: @admin,
        reason_codes: %w[exact_email email_phone_split],
        candidates: [
          CreateService::CandidateInput.new(user: @candidate, match_reason: 'email_phone_split', snapshot: { real_email: true })
        ],
        metadata: { intake_context: 'registration' }
      ).call

      assert result.success?
      assert_includes result.data[:duplicate_review_case].metadata['reason_codes'], 'email_phone_split'
    end

    test 'does not create case when called with empty reason codes' do
      assert_no_difference 'DuplicateReviewCase.count' do
        result = CreateService.new(
          source: :registration_soft_match,
          subject_user: @subject,
          actor: @admin,
          reason_codes: [],
          candidates: []
        ).call

        assert result.failure?
      end
    end

    private

    def assert_no_workflow_side_effects(&)
      assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        assert_no_changes -> { @subject.reload.needs_duplicate_review }, &
      end
    end

    def create_case
      CreateService.new(
        source: :registration_soft_match,
        subject_user: @subject,
        actor: @admin,
        reason_codes: ['name_dob'],
        candidates: [
          CreateService::CandidateInput.new(user: @candidate, match_reason: 'name_dob', snapshot: { real_email: true })
        ],
        metadata: { intake_context: 'registration' }
      ).call
    end
  end
end
