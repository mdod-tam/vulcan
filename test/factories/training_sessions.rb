# frozen_string_literal: true

FactoryBot.define do
  factory :training_session do
    # Required associations. The trainer must be persisted, even when the session itself is only built.
    trainer factory: %i[trainer], strategy: :create
    application { association(:application, :approved, :with_all_proofs, application_date: Date.current, assigned_trainer: trainer) }

    status { :requested } # Matches schema default 0
    assignment_operation_id { SecureRandom.uuid }
    created_at { 2.days.ago }

    scheduled_for { nil }
    completed_at { nil }
    internal_notes { nil }
    constituent_summary { nil }
    summary_locale { nil }
    report_submitted_at { nil }
    reschedule_reason { nil }
    cancelled_at { nil }
    cancellation_reason { nil }
    no_show_notes { nil }

    trait :requested do
      status { :requested }
    end

    trait :scheduled do
      status { :scheduled }
      scheduled_for { 1.day.from_now }
    end

    trait :completed do
      status { :completed }
      completed_at { 1.day.ago }
      created_at { (completed_at || Time.current) - 1.day }
      internal_notes { 'Private training observations.' }
      constituent_summary { 'We practised using the device accessibility controls.' }
      summary_locale { 'en' }
      report_submitted_at { Time.current }
      duration_hours { 1 }
      product_trained_on factory: %i[product] # Explicitly create product for completed sessions
    end

    trait :cancelled do
      status { :cancelled }
      scheduled_for { 1.day.from_now } # Can be future or past
      cancelled_at { Time.current }
      cancellation_reason { 'Training session cancelled reason.' }
      cancellation_initiator { :trainer }
    end

    trait :no_show do
      status { :no_show }
      scheduled_for { 1.day.ago } # Should be in the past
      no_show_notes { 'Training session no show notes.' }
    end

    trait :rescheduled do
      status { :scheduled } # Rescheduled sessions have scheduled status
      scheduled_for { 2.days.from_now } # New scheduled time
      reschedule_reason { 'Training session rescheduled reason.' }
      # Original scheduled_for would be set on the instance before rescheduling
    end
  end
end
