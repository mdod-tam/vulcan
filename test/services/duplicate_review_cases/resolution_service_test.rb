# frozen_string_literal: true

require 'test_helper'

module DuplicateReviewCases
  class ResolutionServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @subject = create(:constituent, needs_duplicate_review: true)
      @review_case = open_case_for(@subject)
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

    def resolve(action:, determination:, rationale: 'reviewed and resolved')
      ResolutionService.new(
        duplicate_review_case: @review_case,
        actor: @admin,
        action: action,
        determination: determination,
        rationale: rationale,
        reason_codes: %w[name_dob]
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
