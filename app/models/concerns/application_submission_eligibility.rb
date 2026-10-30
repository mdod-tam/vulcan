# frozen_string_literal: true

module ApplicationSubmissionEligibility
  extend ActiveSupport::Concern

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

      DuplicateReviewCase.open
                         .for_subject(applicant)
                         .exists?(source: :registration_soft_match)
    end

    # Portal submission and autosave share the active-application and waiting-period rules.
    # +applications+ contains the caller's locked Application records for the applicant.
    # +target_application+ is excluded from the sibling check. The error is a message in +locale+.
    def sibling_application_eligibility_error(applications, target_application:, locale: I18n.locale)
      waiting_period = Policy.waiting_period_years
      result = Applications::AdmissionEligibility.call(
        target_application.user,
        applications: applications, excluding: target_application, waiting_period_years: waiting_period
      )
      case result.reason
      when :blocking_application then I18n.t('applications.creation.refusals.active_application', locale: locale)
      when :waiting_period then I18n.t('applications.creation.refusals.waiting_period', years: waiting_period, locale: locale)
      end
    end
  end
end
