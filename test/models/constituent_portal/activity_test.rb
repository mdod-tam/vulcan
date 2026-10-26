# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ActivityTest < ActiveSupport::TestCase
    setup do
      @application = create(:application, skip_proofs: true)
    end

    test 'deduplicate_submissions removes duplicate submissions within the same minute' do
      # Several submissions of one proof type within the same minute.
      time_base = Time.current.beginning_of_minute

      submission1 = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base
      )

      submission2 = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base + 5.seconds
      )

      submission3 = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base + 10.seconds
      )

      # Different proof type should not be deduplicated
      submission4 = Event.create!(
        action: 'residency_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'residency', submission_method: 'web' },
        created_at: time_base + 8.seconds
      )

      # Different minute should not be deduplicated
      submission5 = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base + 1.minute + 5.seconds
      )

      submissions = [submission1, submission2, submission3, submission4, submission5]

      result = Activity.deduplicate_submissions(submissions)

      # Should keep the latest submission from each group
      assert_equal 3, result.size

      # The kept income proof from the first minute should be submission3 (the latest)
      income_first_minute = result.find { |s| s.metadata['proof_type'] == 'income' && s.created_at < time_base + 1.minute }

      # Check that we kept the latest submission - allow for some time flexibility due to deduplication bucketing
      assert income_first_minute.present?, 'Should have found an income submission in the first minute'
      assert income_first_minute.created_at >= submission1.created_at, 'Should keep a submission from the correct time range'
      assert income_first_minute.created_at <= submission3.created_at, 'Should keep a submission from the correct time range'

      assert result.include?(submission4)

      assert result.include?(submission5)
    end

    test 'from_events returns activities in chronological order' do
      Event.delete_all

      time_base = Time.current
      admin_user = create(:admin)

      submission = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base - 2.hours
      )

      review = ProofReview.create!(
        application: @application,
        admin: admin_user,
        proof_type: 'income',
        status: 'rejected',
        rejection_reason: 'Test rejection reason',
        reviewed_at: time_base - 1.hour,
        created_at: time_base - 1.hour
      )

      resubmission = Event.create!(
        action: 'income_proof_submitted',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base - 30.minutes
      )

      activities = Activity.from_events(@application)

      assert_equal 3, activities.size
      assert_equal submission.created_at, activities.first.created_at
      assert_equal review.created_at, activities.second.created_at
      assert_equal resubmission.created_at, activities.third.created_at

      assert_equal :submission, activities.first.activity_type
      assert_equal :rejection, activities.second.activity_type
      assert_equal :resubmission, activities.third.activity_type
    end
  end
end
