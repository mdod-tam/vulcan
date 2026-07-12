# frozen_string_literal: true

require 'test_helper'

class DuplicateReviewCaseTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @subject = create(:constituent)
  end

  test 'workflow predicates distinguish actionable, nonterminal, and terminal states' do
    open_case = build_case(:open)
    awaiting_case = build_case(:awaiting_information)
    security_case = build_case(:security_review)
    terminal_case = build_case(:resolved_keep_separate)

    assert open_case.pending?
    assert open_case.owns_duplicate_review_flag?
    assert open_case.merge_allowed?
    assert open_case.active_queue?
    assert_not open_case.terminal?

    [awaiting_case, security_case].each do |review_case|
      assert review_case.pending?
      assert review_case.owns_duplicate_review_flag?
      assert review_case.active_queue?
      assert review_case.nonterminal_hold?
      assert_not review_case.merge_allowed?
      assert_not review_case.terminal?
    end

    assert terminal_case.terminal?
    assert_not terminal_case.pending?
    assert_not terminal_case.owns_duplicate_review_flag?
    assert_not terminal_case.merge_allowed?
    assert_not terminal_case.active_queue?
  end

  test 'active queue scope includes every pending state and excludes terminal states' do
    active = %i[open awaiting_information security_review].map { |status| create_case(status) }
    terminal = create_case(:resolved_keep_separate)

    assert_equal active.map(&:id).sort, DuplicateReviewCase.active_queue.where(id: active + [terminal]).ids.sort
  end

  private

  def create_case(status)
    build_case(status).tap(&:save!)
  end

  def build_case(status)
    attributes = {
      source: :registration_soft_match,
      subject_user: @subject,
      deduplication_key: SecureRandom.hex(16),
      metadata: { 'reason_codes' => ['name_dob'] },
      opened_at: Time.current,
      status: status
    }
    if %i[awaiting_information security_review resolved_keep_separate].include?(status)
      attributes.merge!(
        review_rationale: 'Reviewed.',
        reviewed_by: @admin,
        reviewed_at: Time.current
      )
    end
    attributes.merge!(resolved_by: @admin, resolved_at: Time.current) if status == :resolved_keep_separate
    DuplicateReviewCase.new(attributes)
  end
end
