# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperApplicationEligibilityTest < ActiveSupport::TestCase
    setup do
      @original_skip_wait_period = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = true
      @constituent = create(:constituent)
    end

    teardown do
      Application.skip_wait_period_validation = @original_skip_wait_period
    end

    test 'allows a constituent with no application history' do
      assert PaperApplicationEligibility.call(@constituent).eligible?
    end

    test 'blocks any application state that blocks a new submission' do
      create(:application, :in_progress, user: @constituent, application_date: 8.years.ago)

      result = PaperApplicationEligibility.call(@constituent)

      assert_not result.eligible?
      assert_equal :blocking_application, result.reason
      assert_equal 'This constituent already has an active or pending application.',
                   result.refusal_message(subject: :constituent)
    end

    test 'blocks a nonblocking application inside the waiting period' do
      waiting_period = Policy.get('waiting_period_years') || 3
      last_application = create(
        :application,
        :archived,
        user: @constituent,
        application_date: waiting_period.years.ago + 1.day
      )

      result = PaperApplicationEligibility.call(@constituent)

      assert_not result.eligible?
      assert_equal :waiting_period, result.reason
      assert_equal last_application.application_date + waiting_period.years, result.eligible_after
      assert_equal(
        "Not yet eligible for a new application. Eligible after #{result.eligible_after.to_date.strftime('%B %d, %Y')}.",
        result.refusal_message(subject: :dependent)
      )
    end

    test 'allows a nonblocking application exactly at the waiting period boundary' do
      waiting_period = Policy.get('waiting_period_years') || 3
      create(:application, :rejected, user: @constituent, application_date: waiting_period.years.ago)

      assert PaperApplicationEligibility.call(@constituent).eligible?
    end

    test 'allows a nonblocking application after the waiting period' do
      waiting_period = Policy.get('waiting_period_years') || 3
      create(:application, :archived, user: @constituent, application_date: waiting_period.years.ago - 1.day)

      assert PaperApplicationEligibility.call(@constituent).eligible?
    end
  end
end
