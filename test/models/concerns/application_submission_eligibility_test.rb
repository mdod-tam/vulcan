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
end
