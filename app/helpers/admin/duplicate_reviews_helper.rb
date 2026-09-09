# frozen_string_literal: true

module Admin
  module DuplicateReviewsHelper
    SOURCE_LABELS = {
      'registration_soft_match' => 'Found during registration',
      'paper_intake' => 'Paper intake',
      'admin_create' => 'Admin-created',
      'support_claim' => 'Support / claim case',
      'portal_dependent' => 'Portal dependent',
      'post_import_reconciliation' => 'Post-import reconciliation'
    }.freeze

    REASON_LABELS = {
      'name_dob' => 'Name and date of birth match',
      'exact_email' => 'Same email address',
      'exact_email_non_portal' => 'Same email address on a non-portal record',
      'exact_phone' => 'Same phone number',
      'email_phone_split' => 'Email and phone match different records',
      'address_zip' => 'Street address and ZIP code match',
      'address_only_record' => 'Matching address-only record',
      'admin_reviewed' => 'Reviewed by an administrator',
      'manual_review' => 'Manual review'
    }.freeze

    # `resolved_ignored` is the status every non-merge resolution records, so its label has to be
    # true for the decision staff actually made: they kept the records separate. Labelling it
    # "Ignored" contradicted the determination shown beside it on the resolution summary.
    # "Resolved without merge" is accurate for both the current outcome and any legacy row.
    #
    # `resolved_approved` keeps its own label: nothing writes that status any more, but existing
    # rows must still render truthfully rather than being retitled after the fact.
    STATUS_LABELS = {
      'open' => 'Open',
      'resolved_approved' => 'Approved',
      'resolved_ignored' => 'Resolved without merge',
      'resolved_merged' => 'Merged',
      'resolved_superseded' => 'Superseded by merge'
    }.freeze

    PHONE_TYPE_LABELS = {
      'voice' => 'Voice',
      'videophone' => 'Videophone',
      'text' => 'Text/SMS'
    }.freeze

    NO_EMAIL = 'No email on file'
    NO_PHONE = 'No phone on file'
    NO_ADDRESS = 'No address on file'

    # Derived from the server-owned allowlist Users::DuplicateMergeService validates against,
    # so the form can never offer a phone_type the service rejects -- nor silently stop
    # offering one it accepts.
    def duplicate_review_phone_type_options
      User::REAL_PHONE_TYPES.map { |type| [PHONE_TYPE_LABELS.fetch(type, type.humanize), type] }
    end

    def duplicate_review_source_label(source)
      SOURCE_LABELS.fetch(source.to_s, source.to_s.humanize)
    end

    def duplicate_review_status_label(status)
      STATUS_LABELS.fetch(status.to_s, status.to_s.humanize)
    end

    def duplicate_review_reason_label(reason)
      REASON_LABELS.fetch(reason.to_s, reason.to_s.humanize)
    end

    def duplicate_review_presence_label(value)
      value ? 'Yes' : 'No'
    end

    # A queue row represents one durable case, not one subject record. Keep the subject and every
    # recorded candidate together so two exact-pair cases sharing a subject cannot look like a
    # duplicated person row. Retain missing IDs as bounded historical context when a linked user
    # no longer exists.
    def duplicate_review_case_participants(review_case)
      subject = { user: review_case.subject_user, constituent_id: review_case.subject_user_id }
      candidates = review_case.duplicate_review_case_candidates.map do |candidate|
        { user: candidate.candidate_user, constituent_id: candidate.candidate_user_id }
      end

      [subject, *candidates]
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

    def duplicate_review_date_of_birth_display(user)
      user&.date_of_birth&.strftime('%m/%d/%Y') || 'Not on file'
    end

    def duplicate_review_delivery_display(user)
      user&.communication_preference.to_s.humanize.presence || 'Not set'
    end

    def duplicate_review_phone_type_display(phone_type)
      PHONE_TYPE_LABELS.fetch(phone_type.to_s, phone_type.to_s.humanize)
    end

    def duplicate_review_shared_merge_facts(facts)
      rows = []
      if facts.agreed?(:date_of_birth)
        rows << { key: :date_of_birth, label: 'Date of birth',
                  value: duplicate_review_date_of_birth_display(facts.first_user) }
      end
      rows << { key: :phone, label: 'Phone', value: stored_phone_display(facts.first_user) } if facts.agreed?(:phone)
      if facts.agreed?(:phone_type) &&
         [facts.first_user, facts.second_user].any?(&:real_phone?) &&
         User::REAL_PHONE_TYPES.include?(facts.agreed_value(:phone_type))
        rows << { key: :phone_type, label: 'Phone type',
                  value: duplicate_review_phone_type_display(facts.agreed_value(:phone_type)) }
      end
      rows << { key: :address, label: 'Address', value: stored_address_display(facts.first_user) } if facts.agreed?(:address)
      if facts.agreed?(:delivery)
        rows << { key: :delivery, label: 'Official-notice delivery route',
                  value: duplicate_review_delivery_display(facts.first_user) }
      end
      rows
    end

    def duplicate_review_constituent_label(user)
      "#{user.full_name} (Constituent ID #{user.id})"
    end

    # The controller preloads applications for every rendered comparison user, so repeated subject
    # cards reuse the same bounded association data without another query.
    def duplicate_review_record_history(user)
      applications = user.applications.to_a
      {
        application_count: applications.size,
        recent_applications: applications.sort_by { |application| application.application_date || Date.new(1, 1, 1) }
                                         .reverse
                                         .first(5)
      }
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
      open_case = DuplicateReviewCase.open_cases.for_participant(user).order(opened_at: :desc).first
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
