# frozen_string_literal: true

require 'test_helper'

module Applications
  class TrainingQueueSummaryTest < ActiveSupport::TestCase
    setup do
      @now = Time.current.change(usec: 0)
    end

    test 'trainer assignment card includes only approved unassigned requests' do
      before = summary.count
      pending = create(:application, :approved, training_requested_at: @now - 10_000.days, program_disability_groups: ['deafblind'])
      create(:application, :approved, training_requested_at: @now - 11_000.days, assigned_trainer: create(:trainer))
      scheduled = create(:application, :approved)
      create(:training_session, :scheduled, application: scheduled, created_at: @now - 9_999.days, scheduled_for: @now + 5.days)
      create(:application, :in_progress, training_requested_at: @now - 11_000.days)
      completed = create(:application, :approved, training_requested_at: @now - 10.days)
      create(:training_session, :completed, application: completed)

      result = summary

      assert_equal before + 1, result.count
      assert_equal pending, result.oldest.application
      assert_equal ['DeafBlind'], result.oldest.disability_labels
      assert_equal 10_000, result.oldest.days
      assert_equal pending.training_requested_at, result.oldest.entered_at
    end

    test 'assigning a trainer removes the request from the assignment card' do
      before = summary.count
      application = create(:application, :approved, application_date: 1.year.ago, training_requested_at: @now - 5.days)
      assert_equal before + 1, summary.count

      result = TrainerAssignment.assign(application, create(:trainer), actor: create(:admin))

      assert_predicate result, :success?
      assert_equal before, summary.count
      assert_not_includes Application.awaiting_trainer_assignment, application
    end

    test 'a new unassigned request ages from that request instead of completed training history' do
      requested_at = @now - 10_000.days
      application = create(:application, :approved, training_requested_at: requested_at)
      create(:training_session, :completed, application:, created_at: requested_at - 2.days,
                                            completed_at: requested_at - 1.day, report_submitted_at: requested_at - 1.day)

      result = summary

      assert_equal application, result.oldest.application
      assert_equal requested_at, result.oldest.entered_at
      assert_equal 10_000, result.oldest.days
    end

    test 'assignment averages use the first actual trainer assignment after the recorded request' do
      assert_equal 0, summary.assignment_sample_count
      assert_nil summary.average_assignment_days
      admin = create(:admin)
      trainer = create(:trainer)
      first = create(:application, :approved, application_date: 2.years.ago.to_date, training_requested_at: @now - 8.days)
      second = create(:application, :approved, application_date: 2.years.ago.to_date, training_requested_at: @now - 7.days)
      create(:application, :approved, training_requested_at: @now - 10_000.days)

      travel_to(@now - 6.days) { assert_predicate TrainerAssignment.assign(first, trainer, actor: admin), :success? }
      travel_to(@now - 2.days) { assert_predicate TrainerAssignment.assign(second, trainer, actor: admin), :success? }
      travel_to(@now - 1.day) do
        assert_predicate TrainerAssignment.unassign(first, actor: admin), :success?
        assert_predicate TrainerAssignment.assign(first, trainer, actor: admin), :success?
      end

      result = summary

      assert_equal 2, result.assignment_sample_count
      assert_equal 3.5, result.average_assignment_days
    end

    test 'an old assignment before a new request and a request without an assignment have no assignment duration' do
      admin = create(:admin)
      trainer = create(:trainer)
      application = create(:application, :approved, application_date: 2.years.ago.to_date)
      travel_to(@now - 4.days) { assert_predicate TrainerAssignment.assign(application, trainer, actor: admin), :success? }
      application.update!(training_requested_at: @now - 2.days)

      assert_equal 0, summary.assignment_sample_count
      assert_nil summary.average_assignment_days
    end

    private

    def summary
      TrainingQueueSummary.new(now: @now).call
    end
  end
end
