# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ResumeServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: true)
      @review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: 1.day.ago,
        status: :awaiting_information,
        review_rationale: 'Waiting for documents.',
        reviewed_by: @admin,
        reviewed_at: 1.hour.ago
      )
    end

    test 'returns a nonterminal case to actionable review and retains the flag' do
      assert_difference "Event.where(action: 'duplicate_review_case_returned_to_review').count", 1 do
        result = ResumeService.new(
          duplicate_review_case: @review_case,
          actor: @admin,
          rationale: 'Documents received and ready for comparison.'
        ).call
        assert result.success?, result.message
      end

      @review_case.reload
      assert @review_case.open?
      assert @review_case.merge_allowed?
      assert @review_case.active_queue?
      assert_equal @admin, @review_case.reviewed_by
      assert_equal 'Documents received and ready for comparison.', @review_case.review_rationale
      assert @subject.reload.needs_duplicate_review
      event = Event.where(action: 'duplicate_review_case_returned_to_review').last
      assert_equal @admin, event.user
      assert_equal 'awaiting_information', event.metadata['previous_status']
      assert_equal 'open', event.metadata['resulting_status']
      assert_equal 'Documents received and ready for comparison.', event.metadata['rationale']
    end

    test 'rejects open, terminal, non-admin, blank-rationale, and stale forged transitions' do
      @review_case.update!(status: :open)
      open_result = resume(@review_case)
      assert open_result.failure?

      terminal_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: 1.day.ago,
        status: :resolved_keep_separate,
        review_rationale: 'Different people.',
        reviewed_by: @admin,
        reviewed_at: 1.hour.ago,
        resolved_by: @admin,
        resolved_at: 1.hour.ago
      )
      assert resume(terminal_case).failure?

      @review_case.update!(
        status: :security_review,
        review_rationale: 'Specialist review.',
        reviewed_by: @admin,
        reviewed_at: Time.current
      )
      non_admin_result = ResumeService.new(
        duplicate_review_case: @review_case,
        actor: create(:constituent),
        rationale: 'Ready.'
      ).call
      blank_result = ResumeService.new(
        duplicate_review_case: @review_case,
        actor: @admin,
        rationale: ' '
      ).call

      assert non_admin_result.failure?
      assert blank_result.failure?
      assert @review_case.reload.security_review?
    end

    private

    def resume(review_case)
      ResumeService.new(
        duplicate_review_case: review_case,
        actor: @admin,
        rationale: 'Ready to continue.'
      ).call
    end
  end
end
