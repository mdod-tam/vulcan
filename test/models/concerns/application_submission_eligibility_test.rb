# frozen_string_literal: true

require 'test_helper'

class ApplicationSubmissionEligibilityTest < ActiveSupport::TestCase
  setup do
    @original_skip = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = false
    @constituent = create(:constituent)
  end

  teardown do
    Application.skip_wait_period_validation = @original_skip
  end

  test 'excludes the target application from its own sibling check' do
    target = create(:application, :in_progress, user: @constituent, application_date: Date.current)

    assert_nil Application.sibling_application_eligibility_error([target], target_application: target)
  end

  test 'blocks when a blocking (non-archived/rejected) sibling exists' do
    target = Application.new(user: @constituent, application_date: Date.current)
    sibling = create(:application, :in_progress, user: @constituent, application_date: 1.year.ago)

    error = Application.sibling_application_eligibility_error([sibling], target_application: target)

    assert_match(/already have an active application/i, error)
  end

  test 'blocks on the waiting period when only an archived/rejected sibling exists within it' do
    target = Application.new(user: @constituent, application_date: Date.current)
    sibling = create(:application, :rejected, user: @constituent, application_date: 1.year.ago)

    error = Application.sibling_application_eligibility_error([sibling], target_application: target)

    assert_match(/wait 3 years/i, error)
  end

  test 'allows a new application once an archived/rejected sibling is past the waiting period' do
    target = Application.new(user: @constituent, application_date: Date.current)
    sibling = create(:application, :archived, user: @constituent, application_date: 4.years.ago)

    assert_nil Application.sibling_application_eligibility_error([sibling], target_application: target)
  end

  test 'does not block exactly at the waiting-period boundary' do
    target = Application.new(user: @constituent, application_date: Date.current)
    waiting_period = Policy.get('waiting_period_years') || 3
    sibling = create(:application, :rejected, user: @constituent, application_date: waiting_period.years.ago)

    assert_nil Application.sibling_application_eligibility_error([sibling], target_application: target)
  end

  test 'blocks one day inside the waiting-period boundary' do
    target = Application.new(user: @constituent, application_date: Date.current)
    waiting_period = Policy.get('waiting_period_years') || 3
    sibling = create(:application, :rejected, user: @constituent, application_date: waiting_period.years.ago + 1.day)

    error = Application.sibling_application_eligibility_error([sibling], target_application: target)

    assert_match(/wait #{waiting_period} years/i, error)
  end

  test 'skip_wait_period_validation suppresses the waiting-period check but not the active-sibling check' do
    Application.skip_wait_period_validation = true
    target = Application.new(user: @constituent, application_date: Date.current)

    waiting_period_sibling = create(:application, :rejected, user: @constituent, application_date: 1.year.ago)
    assert_nil Application.sibling_application_eligibility_error([waiting_period_sibling], target_application: target)

    active_sibling = create(:application, :in_progress, user: @constituent, application_date: 1.year.ago)
    error = Application.sibling_application_eligibility_error([waiting_period_sibling, active_sibling], target_application: target)
    assert_match(/already have an active application/i, error)
  end

  # `identity_review_pending_for?` is the shared source of truth for both the locked writer and the
  # portal's advisory GET, so its source filter and its open-case filter are pinned directly here
  # rather than only through ApplicationCreator. The source filter in particular is what makes the
  # gate and the `needs_duplicate_review` flag diverge, so it is asserted rather than assumed.
  test 'no identity review is pending for a blank applicant' do
    assert_not Application.identity_review_pending_for?(nil)
  end

  test 'an open registration soft match case gates the applicant' do
    open_review_case_for(@constituent)

    assert Application.identity_review_pending_for?(@constituent)
  end

  test 'an open case from another source does not gate the applicant' do
    open_review_case_for(@constituent, source: :paper_intake)

    assert_not Application.identity_review_pending_for?(@constituent),
               'only registration_soft_match gates; other sources are staff review work'
  end

  test 'a resolved registration soft match case does not gate the applicant' do
    review_case = open_review_case_for(@constituent)
    review_case.update!(
      status: :resolved_ignored,
      resolution_determination: :keep_separate,
      resolution_rationale: 'confirmed different people',
      resolved_by: create(:admin),
      resolved_at: Time.current
    )

    assert_not Application.identity_review_pending_for?(@constituent)
  end

  test 'another user\'s open case does not gate this applicant' do
    open_review_case_for(create(:constituent))

    assert_not Application.identity_review_pending_for?(@constituent)
  end

  private

  def open_review_case_for(user, source: :registration_soft_match)
    DuplicateReviewCase.create!(
      source: source,
      subject_user: user,
      deduplication_key: SecureRandom.hex(16),
      metadata: { 'reason_codes' => ['name_dob'] },
      opened_at: Time.current,
      status: :open
    )
  end
end
