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
      'awaiting_information' => 'Awaiting information',
      'security_review' => 'Security review',
      'resolved_keep_separate' => 'Resolved — kept separate',
      'resolved_relationship' => 'Resolved — relationship confirmed',
      'resolved_merged' => 'Resolved — merged'
    }.freeze

    REVIEW_OUTCOME_OPTIONS = [
      {
        value: 'keep_separate',
        label: 'Keep the records separate',
        kind: 'Terminal',
        description: 'Close this case without moving any data.'
      },
      {
        value: 'authorized_relationship_confirmed',
        label: 'Confirm an existing authorized relationship',
        kind: 'Terminal',
        description: 'Close only after the supported guardian or authorized relationship is already saved.'
      },
      {
        value: 'needs_more_information',
        label: 'Await more information',
        kind: 'Keeps case active',
        description: 'Keep the case in the queue and disable merging until review resumes.'
      },
      {
        value: 'fraud_or_security_review',
        label: 'Send to security review',
        kind: 'Keeps case active',
        description: 'Keep the case in the queue and disable merging. This does not suspend either account.'
      }
    ].freeze

    NO_EMAIL = 'No email on file'
    NO_PHONE = 'No phone on file'
    NO_ADDRESS = 'No address on file'

    def duplicate_review_source_label(source)
      SOURCE_LABELS.fetch(source.to_s, source.to_s.humanize)
    end

    def duplicate_review_status_label(status)
      STATUS_LABELS.fetch(status.to_s, status.to_s.humanize)
    end

    def duplicate_review_status_badge_classes(status)
      case status.to_s
      when 'awaiting_information'
        'bg-amber-100 text-amber-800'
      when 'security_review'
        'bg-red-100 text-red-800'
      when 'open'
        'bg-blue-100 text-blue-800'
      else
        'bg-gray-100 text-gray-700'
      end
    end

    def duplicate_review_outcome_options
      REVIEW_OUTCOME_OPTIONS
    end

    def duplicate_review_state_filter_options
      [['All active states', '']] + DuplicateReviewCase::PENDING_STATUSES.map do |status|
        [duplicate_review_status_label(status), status]
      end
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
      pending_case = DuplicateReviewCase.pending_review.for_subject(user).order(opened_at: :desc).first
      pending_case ? admin_duplicate_review_path(pending_case) : admin_duplicate_reviews_path
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

    # --- Record comparison table (_record_comparison.html.erb) -----------------------

    def stored_login_active_display(user)
      user.public_login_active? ? 'Yes' : 'No'
    end

    def stored_portal_account_display(user)
      user.email_backed_public_portal_account? ? 'Yes (email-backed)' : 'No'
    end

    def stored_account_status_display(user)
      (user.status || 'active').to_s.humanize
    end

    def stored_phone_display_with_type(user)
      display = stored_phone_display(user)
      return display unless user.real_phone?

      "#{display} (#{user.phone_type})"
    end

    def stored_notice_preference_display(user)
      user.communication_preference.to_s.humanize.presence || 'Not set'
    end

    def stored_guardian_relationships_display(user)
      as_guardian = GuardianRelationship.where(guardian_id: user.id).count
      as_dependent = GuardianRelationship.where(dependent_id: user.id).count
      "As guardian: #{as_guardian} dependent(s) · As dependent: #{as_dependent} guardian(s)"
    end

    # Rows in the scannable comparison table on the merge detail page. Each entry is
    # [label, display_method]; the view mutes rows where the two values are equal and
    # visibly flags rows where they differ, since a same-looking pair is not worth
    # scanning closely but a difference is exactly what the admin needs to notice.
    def record_comparison_rows
      [
        ['Login active', :stored_login_active_display],
        ['Public portal account', :stored_portal_account_display],
        ['Account status', :stored_account_status_display],
        ['Email', :stored_email_display],
        ['Phone', :stored_phone_display_with_type],
        ['Address', :stored_address_display],
        ['Notice preference', :stored_notice_preference_display]
      ]
    end

    # One read-only security snapshot per record keeps the warning and displayed facts
    # consistent while avoiding duplicate count/existence queries in the partial.
    # SMS only counts as an enrolled factor after verification; unfinished legacy setup
    # rows remain visible separately and never affect the MFA-method warning.
    def auth_security_snapshot(user)
      {
        credential_counts: auth_credential_counts(user),
        active_sessions: user.sessions.active.count,
        pending_recovery: user.recovery_requests.pending.exists?,
        active_secure_form: SecureRequestForm.active.exists?(recipient_id: user.id)
      }
    end

    def auth_credential_counts(user)
      {
        webauthn: user.webauthn_credentials.count,
        totp: user.totp_credentials.count,
        sms: user.sms_credentials.verified.count,
        pending_sms: user.sms_credentials.where(verified_at: nil).count
      }
    end

    # Which auth method types (not counts) a user currently has at least one credential
    # for. Two passkeys vs one passkey is a resilience/usability signal, not a
    # security-relevant difference; a different set of methods (passkey vs SMS, MFA vs
    # none, TOTP vs WebAuthn) is what actually matters for the merge decision, so the
    # comparison is over which methods are present, never how many.
    def mfa_method_set(security_snapshot)
      security_snapshot.fetch(:credential_counts)
                       .slice(:webauthn, :totp, :sms)
                       .select { |_method, count| count.positive? }
                       .keys
    end

    # Users::DuplicateMergeService blocks the merge when the record being retired (the
    # non-canonical side) has a pending recovery request or an active secure request
    # form -- but canonical isn't chosen yet when this renders, so the copy must be
    # conditional on this specific user, not a blanket "merge is blocked" statement.
    def retirement_blocker_message(user, role_label, security_snapshot:)
      pending_recovery = security_snapshot.fetch(:pending_recovery)
      active_secure_form = security_snapshot.fetch(:active_secure_form)
      return nil unless pending_recovery || active_secure_form

      reasons = [
        ('pending recovery request' if pending_recovery),
        ('active secure form' if active_secure_form)
      ].compact
      verb = reasons.size > 1 ? 'are' : 'is'
      "#{role_label} ##{user.id} cannot be retired (merged away) until its #{reasons.to_sentence} #{verb} resolved."
    end

    def mfa_imbalance?(subject_security, candidate_security)
      mfa_method_set(subject_security) != mfa_method_set(candidate_security)
    end
  end
end
