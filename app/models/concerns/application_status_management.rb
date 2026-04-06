# frozen_string_literal: true

module ApplicationStatusManagement
  extend ActiveSupport::Concern

  included do
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
    scope :active, -> { where(status: %i[in_progress awaiting_proof reminder_sent awaiting_dcf]) }
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
        where(status: statuses[:awaiting_dcf])
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

  # Unified reconciliation entry point for workflow state transitions.
  # Checks whether the application should be auto-approved (all requirements met)
  # or escalated to DCF (proofs approved, cert pending). Row-locked, idempotent,
  # and safe to call redundantly from any writer path.
  def reconcile_workflow_state!(actor:, trigger: nil)
    with_lock do
      reload
      return if status_approved? || status_rejected? || status_archived?

      if all_requirements_met?
        transition_status!(
          :approved,
          actor: actor,
          notes: 'Auto-approved based on all requirements being met',
          metadata: { trigger: 'auto_approval', source: trigger&.to_s }.compact
        )
        return
      end

      escalate_to_dcf!(actor: actor, trigger: trigger) if required_proofs_for_dcf_approved?
    end
  end

  # Consolidates DCF escalation: transitions to awaiting_dcf and conditionally
  # requests medical certification. Safe to call from any path — idempotent,
  # locked, and self-healing (repairs a missing cert request on re-entry).
  def escalate_to_dcf!(actor:, trigger: nil)
    with_lock do
      reload

      return if status_approved? || status_rejected? || status_archived?

      transition_status!(
        :awaiting_dcf,
        actor: actor,
        notes: 'Requesting medical certification documents',
        metadata: { trigger: trigger&.to_s }.compact
      ) unless status_awaiting_dcf?

      return unless required_proofs_for_dcf_approved?
      return unless medical_certification_status_not_requested?

      update!(medical_certification_status: :requested)
      MedicalProviderMailer.request_certification(self).deliver_later
    end
  end

  private

  def all_requirements_met?
    required_proofs_approved? &&
      medical_certification_status_approved?
  end
end
