# frozen_string_literal: true

module ApplicationStatusManagement
  extend ActiveSupport::Concern

  included do
    after_save :handle_status_change, if: :saved_change_to_status?
    after_save :auto_approve_if_eligible, if: :requirements_met_for_approval?

    enum :application_type, {
      new: 0,
      renewal: 1
    }, prefix: true

    enum :submission_method, {
      online: 0,
      paper: 1,
      phone: 2,
      email: 3
    }, prefix: true

    # Status-related scopes - These rely on the enum defined in the model
    scope :active, -> { where(status: %i[in_progress needs_information reminder_sent awaiting_documents]) }
    scope :draft, -> { where(status: :draft) }
    scope :submitted, -> { where.not(status: :draft) }
    scope :filter_by_status, ->(status) { where(status: status) if status.present? }
    scope :filter_by_type, lambda { |filter_type|
      case filter_type
      when 'proofs_needing_review'
        where(
          'income_proof_status = ? OR residency_proof_status = ?',
          income_proof_statuses[:not_reviewed],
          residency_proof_statuses[:not_reviewed]
        )
      when 'proofs_rejected'
        where(
          income_proof_status: income_proof_statuses[:rejected],
          residency_proof_status: residency_proof_statuses[:rejected]
        )
      when 'awaiting_medical_response'
        where(status: statuses[:awaiting_documents])
      when 'digitally_signed_needs_review'
        where(
          document_signing_status: document_signing_statuses[:signed]
        ).where.not(
          medical_certification_status: [
            medical_certification_statuses[:approved],
            medical_certification_statuses[:rejected]
          ]
        )
      end
    }
    scope :sorted_by, lambda { |column, direction|
      direction = direction&.downcase == 'desc' ? 'desc' : 'asc'

      if column.present?
        if column.start_with?('user.')
          association = 'users'
          column_name = column.split('.').last
          joins(:user).order("#{association}.#{column_name} #{direction}")
        elsif column_names.include?(column)
          order("#{column} #{direction}")
        else
          order(application_date: :desc)
        end
      else
        order(application_date: :desc)
      end
    }
  end

  def submitted?
    !status_draft?
  end

  private

  # Handles transitions to specific statuses that trigger automated actions.
  # Currently triggers the auto-request for medical certification when transitioning to 'awaiting_documents'.
  def handle_status_change
    return unless status_previously_changed?(to: 'awaiting_documents')

    handle_awaiting_documents_transition
  end

  # --- Auto Request Medical Certification Process ---
  # Triggered when the application status transitions to 'awaiting_documents'.
  # Checks if income and residency proofs are approved.
  # If so, updates the medical certification status to 'requested' and sends an email to the medical provider.
  def handle_awaiting_documents_transition
    # Ensure income and residency proofs are approved
    return unless all_proofs_approved?
    # Avoid re-requesting if already requested
    return if medical_certification_status_requested?

    # Update certification status and send email
    with_lock do
      update!(medical_certification_status: :requested)
      MedicalProviderMailer.request_certification(self).deliver_later
    end
  end

  # --- Auto Approve Application Process ---
  # Checks if the application itself is eligible for auto-approval.
  # Eligibility requires income proof, residency proof, AND medical certification to be approved.
  # This method is triggered after save if any of the relevant proof statuses change.
  def requirements_met_for_approval?
    # Only run this when relevant fields have changed
    return false unless saved_change_to_income_proof_status? ||
                        saved_change_to_residency_proof_status? ||
                        saved_change_to_medical_certification_status?

    # Only auto-approve applications that aren't already approved
    return false if status_approved?

    # Check if all requirements are met (income, residency, and medical certification approved)
    all_requirements_met?
  end

  def all_requirements_met?
    income_proof_status_approved? &&
      residency_proof_status_approved? &&
      medical_certification_status_approved?
  end

  # Auto-approves the application when all requirements are met
  # Uses proper Rails update mechanisms to ensure audit trails are created
  def auto_approve_if_eligible
    previous_status = status
    update_application_status_to_approved
    create_auto_approval_audit_event(previous_status)
  end

  # Updates the application status using Rails update! method
  # The after_save callback handles status change record creation automatically
  def update_application_status_to_approved
    # Use Current.user (the admin who triggered the action) for audit trail
    # Store notes for the callback to use
    @pending_status_change_user = Current.user
    @pending_status_change_notes = 'Auto-approved based on all requirements being met'

    # Update status - log_status_change callback handles ApplicationStatusChange creation
    update!(status: 'approved')
  end

  # Creates an audit event for the auto-approval
  def create_auto_approval_audit_event(previous_status)
    return unless defined?(Event) && Event.respond_to?(:create)

    begin
      # Use Current.user if available, otherwise fall back to a system user for automated processes
      acting_user = Current.user || User.find_by(email: 'system@example.com') || User.first
      Event.create!(
        user: acting_user,
        action: 'application_auto_approved',
        metadata: {
          application_id: id,
          old_status: previous_status,
          new_status: status,
          timestamp: Time.current.iso8601,
          auto_approval: true,
          triggered_by_user_id: acting_user&.id
        }
      )
    rescue StandardError => e
      # Log error but don't prevent the auto-approval
      Rails.logger.error("Failed to create event for auto-approval: #{e.message}")
    end
  end
end
