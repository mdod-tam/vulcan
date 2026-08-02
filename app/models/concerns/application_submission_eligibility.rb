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
    # The identity-review admission rule, in one place so the locked writer and the portal form
    # cannot drift. Applications::ApplicationCreator asks under lock and refuses; the portal form
    # asks on GET so it can warn and disable submission before the constituent selects documents a
    # refusal would silently discard -- browsers cannot repopulate a file input. The unlocked read
    # is advisory only; the locked one still decides.
    #
    # Only the +applicant+ is checked, never the acting guardian, and only an open
    # +registration_soft_match+ case gates. Cases from the other live sources are staff review work
    # rather than submission blockers, and the candidate account named by someone else's case is
    # never gated merely for being matched. The durable open case is the authority, not
    # +users.needs_duplicate_review+, which is a denormalized badge and can be cleared on its own.
    def identity_review_pending_for?(applicant)
      return false if applicant.blank?

      DuplicateReviewCase.open_cases
                         .for_subject(applicant)
                         .exists?(source: :registration_soft_match)
    end

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
