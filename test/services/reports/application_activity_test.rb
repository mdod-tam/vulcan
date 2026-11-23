# frozen_string_literal: true

require 'test_helper'

module Reports
  class ApplicationActivityTest < ActiveSupport::TestCase
    test 'uses recorded lifecycle and certification dates for historical counts and completed waits' do
      travel_to Time.zone.local(2026, 8, 20, 12) do
        period = Period.new(3)
        baseline = ApplicationActivity.new(period)
        queues = baseline.backlog
        intake = baseline.intake
        stages = baseline.current_stages
        application = create(:application, :approved, :with_all_proofs, submission_method: :paper, created_at: Time.zone.local(2026, 6, 10))
        stage_change(application, 'awaiting_proof', 'awaiting_dcf', Time.zone.local(2026, 6, 13))
        stage_change(application, 'not_requested', 'requested', Time.zone.local(2026, 6, 14), :disability_certification)
        stage_change(application, 'requested', 'received', Time.zone.local(2026, 7, 2), :disability_certification)
        stage_change(application, 'received', 'approved', Time.zone.local(2026, 8, 2), :disability_certification)
        stage_change(application, 'awaiting_dcf', 'approved', Time.zone.local(2026, 8, 2))

        activity = ApplicationActivity.new(period)
        assert_equal queues.fetch('Waiting for certification').zip([1, 0, 0]).map(&:sum), activity.backlog.fetch('Waiting for certification')
        assert_equal queues.fetch('Certifications to review').zip([0, 1, 0]).map(&:sum), activity.backlog.fetch('Certifications to review')
        paper = activity.time_in_stages.fetch('Paper entered by staff')
        assert_equal 3.0, paper[0]
        assert_equal 19.0, paper[2]
        assert_equal 31.0, paper[3]
        assert_equal intake.fetch('Paper entered by staff') + 1, activity.intake.fetch('Paper entered by staff')
        assert_equal stages.fetch('Waiting for evaluation') + 1, activity.current_stages.fetch('Waiting for evaluation')
      end
    end

    private

    def stage_change(application, from, to, date, type = :status)
      application.status_changes.create!(from_status: from, to_status: to, changed_at: date, change_type: type)
    end
  end
end
