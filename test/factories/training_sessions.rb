# frozen_string_literal: true

FactoryBot.define do
  factory :training_session do
    # Required associations
    application
    trainer # Add default trainer association

    # Default status
    status { :requested } # Matches schema default 0

    # Optional attributes (often set via traits)
    scheduled_for { nil }
    completed_at { nil }
    notes { nil }
    reschedule_reason { nil }
    cancelled_at { nil }
    cancellation_reason { nil }
    no_show_notes { nil }

    # Traits for different statuses
    trait :scheduled do
      status { :scheduled }
      scheduled_for { 1.day.from_now }
    end

    trait :completed do
      status { :completed }
      completed_at { 1.day.ago }
      notes { 'Training session completed notes.' }
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

    # Add other traits as needed for specific test scenarios
  end
end
