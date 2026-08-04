# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ResolutionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: true)
      @review_case = open_case_for(@subject)
    end

    # A case recorded as "needs more information" was being closed, which released the PR5a
    # submission gate and cleared the subject's review flag -- so the subject could submit while
    # their identity was still genuinely undecided, and the case vanished from the admin flagged
    # list and badges at the same moment. Staff who need more information leave the case open.
    test 'needs_more_information cannot resolve a case' do
      result = nil
      assert_no_changes -> { @subject.reload.needs_duplicate_review } do
        result = resolve(action: :keep_separate, determination: 'needs_more_information')
      end

      assert_not result.success?
      assert_match(/stays open/i, result.message)
      assert @review_case.reload.open?, 'the case must remain open and in the queue'
      assert_nil @review_case.resolved_at
    end

    # The gate is the reason the above matters, so assert it directly rather than inferring it
    # from the case status -- and assert the refusal leaves no terminal-resolution audit event,
    # since a case that was never decided must not carry a record saying it was.
    test 'a rejected needs_more_information resolution leaves the submission gate closed' do
      assert Application.identity_review_pending_for?(@subject)

      assert_no_difference -> { Event.where(action: 'duplicate_review_case_resolved').count } do
        resolve(action: :keep_separate, determination: 'needs_more_information')
      end

      assert Application.identity_review_pending_for?(@subject),
             'final submission must stay blocked while the case is undecided'
    end

    # The narrowness is deliberate, but assert it against the constant rather than by exercising an
    # untriaged determination. Asserting that `fraud_or_security_review` *succeeds* would encode an
    # unanswered policy question as expected behavior, so making it non-terminal later — the
    # currently recommended answer — would read as a regression rather than the intended fix.
    #
    # This fails if someone widens the block without deciding, and is simply updated when the
    # PR5c matrix legitimately widens it.
    test 'only the determination with a recorded decision is blocked' do
      assert_equal %w[needs_more_information],
                   DuplicateReviewCases::ResolutionService::NON_TERMINAL_DETERMINATIONS
    end

    test 'approve resolves the case and clears the review flag' do
      result = nil
      assert_changes -> { @subject.reload.needs_duplicate_review }, from: true, to: false do
        result = resolve(action: :approve, determination: 'same_person_confirmed')
      end

      assert result.success?
      @review_case.reload
      assert_equal 'resolved_approved', @review_case.status
      assert_equal 'same_person_confirmed', @review_case.resolution_determination
      assert_equal @admin, @review_case.resolved_by
      assert @review_case.resolved_at.present?
    end

    test 'ignore resolves the case as ignored' do
      result = resolve(action: :ignore, determination: 'keep_separate')
      assert result.success?
      assert_equal 'resolved_ignored', @review_case.reload.status
    end

    test 'keep separate resolves without moving contact facts' do
      original_phone = @subject.phone
      result = resolve(action: :keep_separate, determination: 'keep_separate')
      assert result.success?
      assert_equal 'resolved_ignored', @review_case.reload.status
      assert_equal 'keep_separate', @review_case.resolution_determination
      assert_equal original_phone, @subject.reload.phone
    end

    test 'requires a rationale' do
      result = resolve(action: :approve, determination: 'same_person_confirmed', rationale: '  ')
      assert result.failure?
      assert_equal 'open', @review_case.reload.status
    end

    test 'requires an admin actor' do
      result = ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: create(:constituent),
        action: :approve,
        determination: 'same_person_confirmed',
        rationale: 'looks fine'
      ).call
      assert result.failure?
      assert_equal 'open', @review_case.reload.status
    end

    # Reason codes land in immutable resolution metadata and audit evidence, so they are checked
    # against a server-owned vocabulary. Validating in preflight (not only at the model) matters
    # here: resolve_case! writes with update!, and #call rescues StaleCaseError only, so a
    # model-level rejection would surface as an unhandled RecordInvalid rather than a failure.
    test 'rejects a reason code outside the server-owned vocabulary' do
      result = resolve(action: :approve, determination: 'same_person_confirmed', reason_codes: ['name_dob', 'free text'])
      assert result.failure?
      assert_match(/unsupported reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'rejects more reason codes than the cap allows' do
      result = resolve(action: :approve, determination: 'same_person_confirmed',
                       reason_codes: Array.new(DuplicateReviewCase::MAX_REASON_CODES + 1) { |i| "code-#{i}" })
      assert result.failure?
      assert_match(/too many reason/i, result.message)
      assert_equal 'open', @review_case.reload.status
    end

    test 'accepts operator reason codes alongside detection match reasons' do
      result = resolve(action: :approve, determination: 'same_person_confirmed', reason_codes: %w[name_dob admin_reviewed])
      assert result.success?, result.message
      assert_equal %w[name_dob admin_reviewed], @review_case.reload.resolution_metadata['reason_codes']
    end

    test 'does not clear review flag when another open case remains' do
      open_case_for(@subject)
      resolve(action: :ignore, determination: 'keep_separate')
      assert @subject.reload.needs_duplicate_review
    end

    test 'emits a resolution audit event' do
      assert_difference 'Event.where(action: \'duplicate_review_case_resolved\').count', 1 do
        resolve(action: :approve, determination: 'same_person_confirmed')
      end
    end

    private

    def resolve(action:, determination:, rationale: 'reviewed and resolved', reason_codes: %w[name_dob])
      ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: @admin,
        action: action,
        determination: determination,
        rationale: rationale,
        reason_codes: reason_codes
      ).call
    end

    def open_case_for(user)
      DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: user,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
    end
  end
end
