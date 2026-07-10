# frozen_string_literal: true

module Admin
  module DuplicateReviewsHelper
    SOURCE_LABELS = {
      'registration_soft_match' => 'Registration match',
      'paper_intake' => 'Paper intake',
      'admin_create' => 'Admin-created',
      'support_claim' => 'Support / claim case',
      'portal_dependent' => 'Portal dependent'
    }.freeze

    STATUS_LABELS = {
      'open' => 'Open',
      'resolved_approved' => 'Approved',
      'resolved_ignored' => 'Ignored',
      'resolved_merged' => 'Merged'
    }.freeze

    NO_EMAIL = 'No email on file'
    NO_PHONE = 'No phone on file'
    NO_ADDRESS = 'No address on file'

    def duplicate_review_source_label(source)
      SOURCE_LABELS.fetch(source.to_s, source.to_s.humanize)
    end

    def duplicate_review_status_label(status)
      STATUS_LABELS.fetch(status.to_s, status.to_s.humanize)
    end

    # Stored record truth (not the delivery/effective fallback). Synthetic placeholders
    # are hidden so the queue never presents synthetic contact as a real fact.
    def stored_email_display(user)
      return NO_EMAIL if user.blank? || !user.real_email?

      user.email
    end

    def stored_phone_display(user)
      return NO_PHONE if user.blank? || !user.real_phone?

      user.phone
    end

    def stored_address_display(user)
      return NO_ADDRESS if user.blank?

      parts = [user.physical_address_1, user.physical_address_2, [user.city, user.state].compact_blank.join(', '), user.zip_code]
      parts.compact_blank.join(' · ').presence || NO_ADDRESS
    end

    # Whether a recorded candidate link still points at an accessible, non-merged user.
    def candidate_link_state(candidate)
      return 'unavailable' if candidate.candidate_user_id.present? && candidate.candidate_user.nil?
      return 'no_link' if candidate.candidate_user_id.blank?
      return 'merged' if candidate.candidate_user.merged?

      'current'
    end

    # Entry point from a user page: open case detail when one exists, otherwise the queue.
    def admin_duplicate_review_entry_path(user)
      open_case = DuplicateReviewCase.open_cases.for_subject(user).order(opened_at: :desc).first
      open_case ? admin_duplicate_review_path(open_case) : admin_duplicate_reviews_path
    end

    # Surfaces the flag on the application page too, not just the user/queue pages.
    # Staff working from an application (e.g. a soft-matched paper intake) would
    # otherwise have no on-page signal that a duplicate review is pending for the
    # applicant or their managing guardian.
    def duplicate_review_pending_badge(application)
      flagged_user = [application.user, application.managing_guardian].compact.find(&:needs_duplicate_review?)
      return if flagged_user.blank?

      link_to 'Duplicate review pending',
              admin_duplicate_review_entry_path(flagged_user),
              class: 'px-3 py-2 text-sm font-medium rounded-full whitespace-nowrap inline-flex items-center ' \
                     'justify-center bg-yellow-100 text-yellow-800 hover:bg-yellow-200',
              data: { testid: 'duplicate-review-pending-badge' }
    end

    def candidate_link_state_label(candidate)
      {
        'current' => 'Current record',
        'merged' => 'Already merged',
        'unavailable' => 'Record no longer exists',
        'no_link' => 'No stored candidate link'
      }.fetch(candidate_link_state(candidate))
    end
  end
end
