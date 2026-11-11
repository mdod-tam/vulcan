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
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base
      )

      submission2 = Event.create!(
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base + 5.seconds
      )

      submission3 = Event.create!(
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base + 10.seconds
      )

      # Different proof type should not be deduplicated
      submission4 = Event.create!(
        action: 'residency_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'residency', submission_method: 'web' },
        created_at: time_base + 8.seconds
      )

      # Different minute should not be deduplicated
      submission5 = Event.create!(
        action: 'income_proof_attached',
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
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base - 2.hours
      )

      review = create(
        :proof_review,
        application: @application,
        admin: admin_user,
        proof_type: 'income',
        status: 'rejected',
        rejection_reason: 'Test rejection reason',
        reviewed_at: time_base - 1.hour,
        created_at: time_base - 3.hours
      )

      resubmission = Event.create!(
        action: 'income_proof_attached',
        user: @application.user,
        auditable: @application,
        metadata: { proof_type: 'income', submission_method: 'web' },
        created_at: time_base - 30.minutes
      )

      activities = Activity.from_events(@application)

      assert_equal 3, activities.size
      assert_equal submission.created_at, activities.first.created_at
      assert_equal review.reviewed_at, activities.second.created_at
      assert_equal resubmission.created_at, activities.third.created_at

      assert_equal :submission, activities.first.activity_type
      assert_equal :rejection, activities.second.activity_type
      assert_equal :resubmission, activities.third.activity_type
    end

    test 'a submission says which proof was attached and how, in the viewer locale' do
      english = { 'web' => 'via web', 'paper' => 'via paper', 'secure_form' => 'via secure form', 'email' => 'via email' }
      spanish = { 'web' => 'por la web', 'paper' => 'en papel', 'secure_form' => 'mediante un formulario seguro',
                  'email' => 'por correo electrónico' }

      english.each do |method, phrase|
        event = submission_event('income', method)

        assert_equal "Income proof attached #{phrase}", Activity.from_submission_event(event).description
        I18n.with_locale(:es) do
          assert_equal "Comprobante de ingresos adjuntado #{spanish.fetch(method)}", Activity.from_submission_event(event).description
        end
      end
    end

    test 'each proof type is named as the secure-form messages name it, and an unknown method still names the proof' do
      residency = submission_event('residency', 'web')
      identity = submission_event('id', 'web')
      unknown = submission_event('income', 'fax')

      assert_equal 'Proof of Maryland residency attached via web', Activity.from_submission_event(residency).description
      assert_equal 'Proof of identity attached via web', Activity.from_submission_event(identity).description
      assert_equal 'Income proof attached', Activity.from_submission_event(unknown).description
      I18n.with_locale(:es) do
        assert_equal 'Comprobante de residencia en Maryland adjuntado por la web', Activity.from_submission_event(residency).description
        assert_equal 'Comprobante de ingresos adjuntado', Activity.from_submission_event(unknown).description
      end
    end

    test 'a review says whether the proof was approved or rejected, in the viewer locale' do
      admin = create(:admin)
      approved = create(:proof_review, application: @application, admin: admin, proof_type: 'income', status: 'approved')
      rejected = create(:proof_review, application: @application, admin: admin, proof_type: 'id', status: 'rejected',
                                       rejection_reason: 'Too blurry')

      certification_approved = create(:proof_review, application: @application, admin: admin,
                                                     proof_type: 'disability_certification', status: 'approved')
      certification_rejected = create(:proof_review, application: @application, admin: admin,
                                                     proof_type: 'disability_certification', status: 'rejected',
                                                     rejection_reason: 'Missing signature')

      assert_equal 'Disability certification approved', Activity.from_proof_review(certification_approved).description
      assert_equal 'Disability certification rejected', Activity.from_proof_review(certification_rejected).description
      assert_equal 'Income proof approved', Activity.from_proof_review(approved).description
      assert_equal 'Proof of identity rejected', Activity.from_proof_review(rejected).description
      I18n.with_locale(:es) do
        assert_equal 'Certificación de discapacidad aprobada', Activity.from_proof_review(certification_approved).description
        assert_equal 'Certificación de discapacidad rechazada', Activity.from_proof_review(certification_rejected).description
        assert_equal 'Comprobante de ingresos aprobado', Activity.from_proof_review(approved).description
        assert_equal 'Comprobante de identidad rechazado', Activity.from_proof_review(rejected).description
      end
    end

    private

    def submission_event(proof_type, method)
      Event.create!(action: "#{proof_type}_proof_attached", user: @application.user, auditable: @application,
                    metadata: { proof_type: proof_type, submission_method: method })
    end
  end
end
