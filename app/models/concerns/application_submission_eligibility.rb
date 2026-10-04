# frozen_string_literal: true

module ApplicationSubmissionEligibility
  extend ActiveSupport::Concern

  included do
    # The test suite can disable the waiting-period rule globally.
    cattr_accessor :skip_wait_period_validation, default: false
  end

  # Mirrors the +blocking_new_submission+ scope for a loaded record without another query.
  def blocking_new_submission?
    !status_archived? && !status_rejected?
  end

  # The applicant's own unmanaged draft, or a dependent's draft that +actor_id+ manages.
  def resumable_portal_draft_for?(actor_id)
    status_draft? && managing_guardian_id == (user_id == actor_id ? nil : actor_id)
  end

  class_methods do
    # Portal autosave and the full form resume the same draft.
    # Writers pass a locked applicant inventory so concurrent requests do not create duplicate drafts.
    # The portal GET passes an unlocked inventory.
    def resumable_portal_draft(applications, actor_id:)
      Array(applications).select { |application| application.resumable_portal_draft_for?(actor_id) }
                         .max_by { |application| [application.created_at, application.id] }
    end

    # Applications::ApplicationCreator applies this rule under lock. The portal GET uses an advisory read.
    # The form warns before document selection because browsers cannot repopulate a file input.
    #
    # Only the +applicant+'s open +registration_soft_match+ case blocks submission.
    # Cases for the acting guardian or another subject do not block it. Other case sources require staff review only.
    # The durable case is authoritative. +users.needs_duplicate_review+ is a separate badge that can be cleared independently.
    def identity_review_pending_for?(applicant)
      return false if applicant.blank?

      DuplicateReviewCase.open_cases
                         .for_subject(applicant)
                         .exists?(source: :registration_soft_match)
    end

    # Portal submission and autosave share the active-application and waiting-period rules.
    # +applications+ contains the caller's locked Application records for the applicant.
    # +target_application+ is excluded from the sibling check.
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
