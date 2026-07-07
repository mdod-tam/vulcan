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
