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

    test 'rejected and archived applications do not start the waiting period' do
      %i[rejected archived].each do |status|
        create(:application, user: @constituent, status: status, application_date: 1.day.ago)
      end

      result = PaperApplicationEligibility.call(@constituent)

      assert result.eligible?
      assert_nil result.waiting_period_ends_at
      assert_nil result.eligible_after
    end

    test 'approved admission blocks before and after the waiting duration elapses' do
      [1.year.ago, Policy.waiting_period_years.years.ago, 8.years.ago].each do |date|
        application = create(:application, :approved, user: create(:constituent), application_date: date)
        result = PaperApplicationEligibility.call(application.user)

        assert_equal :blocking_application, result.reason
        assert_nil result.eligible_after
        assert_equal application.application_date + Policy.waiting_period_years.years, result.waiting_period_ends_at
        assert_equal date > Policy.waiting_period_years.years.ago, result.waiting_period_active?
      end
    end

    test 'uses only persisted supplied inventory and excludes its target draft' do
      create(:application, :in_progress, user: @constituent)
      target = create(:application, :draft, user: @constituent)
      unsaved = build(:application, :approved, user: @constituent)

      result = PaperApplicationEligibility.call(@constituent, applications: [target, unsaved], excluding: target)

      assert result.eligible?
      assert_nil result.waiting_period_ends_at
      assert_equal :blocking_application, PaperApplicationEligibility.call(@constituent).reason
    end

    test 'a real sibling blocks even when waiting validation is skipped' do
      target = create(:application, :draft, user: @constituent)
      sibling = create(:application, :approved, user: @constituent, application_date: 1.day.ago)

      result = PaperApplicationEligibility.call(@constituent, applications: [target, sibling], excluding: target, skip_wait_period: true)

      assert_equal :blocking_application, result.reason
      assert result.waiting_period_active?
    end

    test 'an approved record without a date blocks without inventing a waiting date' do
      approved = create(:application, :approved, user: @constituent)
      approved.application_date = nil

      result = PaperApplicationEligibility.call(@constituent, applications: [approved])

      assert_equal :blocking_application, result.reason
      assert_nil result.waiting_period_ends_at
      assert_not result.waiting_period_active?
    end
  end
end
