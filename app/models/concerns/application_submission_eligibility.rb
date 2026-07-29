# frozen_string_literal: true

module ApplicationSubmissionEligibility
  extend ActiveSupport::Concern

  included do
    # Allow the test suite to disable the waiting-period check globally.
    cattr_accessor :skip_wait_period_validation, default: false
  end

  # Instance-level mirror of the +blocking_new_submission+ scope, for checking an
  # already-loaded/locked record without an extra query.
  def blocking_new_submission?
    !status_archived? && !status_rejected?
  end

  class_methods do
    # Shared eligibility policy for "one active application, waiting-period" so portal final
    # submission and portal autosave apply the same rule against their already-locked inventory.
    # +applications+ is the caller's locked inventory for the applicant (any enumerable of
    # Application records); +target_application+ is excluded from its own sibling check.
    def sibling_application_eligibility_error(applications, target_application:)
      siblings = Array(applications).select(&:persisted?).reject { |app| app.id == target_application.id }
      has_blocking_sibling = siblings.any?(&:blocking_new_submission?)
      return 'You already have an active application; wait for it to be processed before starting another.' if has_blocking_sibling

      return nil if skip_wait_period_validation

      most_recent = siblings.filter_map(&:application_date).max
      return nil if most_recent.blank?

      waiting_period = Policy.get('waiting_period_years') || 3
      return nil unless most_recent > waiting_period.years.ago

      "You must wait #{waiting_period} years before submitting a new application."
    end
  end
end
