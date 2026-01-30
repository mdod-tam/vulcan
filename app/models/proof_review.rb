# frozen_string_literal: true

# Manages the review process for income and residency proof documents
class ProofReview < ApplicationRecord
  # Associations
  belongs_to :application
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, class_name: 'User'

  # Enums (using the original syntax to avoid argument errors)
  enum :proof_type, { income: 0, residency: 1 }, prefix: true
  enum :status, { approved: 0, rejected: 1 }, prefix: true
  enum :submission_method, { web: 0, email: 1, scanned: 2, paper: 3 }, prefix: true

  # Validations
  validates :proof_type, presence: true
  validates :status, presence: true
  validates :reviewed_at, presence: true
  validates :rejection_reason, presence: true, if: :status_rejected?
  validate :application_must_be_active
  validate :proof_must_be_attached, if: :should_validate_proof_attachment?
  validate :admin_must_be_admin_type

  # Callbacks
  before_validation :set_reviewed_at, on: :create
  after_commit :handle_post_review_actions, on: :create
  after_commit :check_all_proofs_approved, on: :create, if: :status_approved?

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :by_admin, ->(admin_id) { where(admin_id: admin_id) }
  scope :rejections, -> { where(status: :rejected) }
  scope :last_3_days, -> { where('created_at > ?', 3.days.ago) }

  private

  def set_reviewed_at
    self.reviewed_at ||= Time.current
  end

  def application_must_be_active
    errors.add(:application, 'cannot be reviewed when archived') if application&.status_archived?
  end

  def should_validate_proof_attachment?
    # Don't validate proof attachment for paper submissions with rejected proofs
    # This check is the highest priority and applies in all environments
    return false if status_rejected? && submission_method_paper?

    # Skip validation in test environment unless explicitly enabled
    return false if Rails.env.test? && ENV['VALIDATE_PROOF_ATTACHMENTS'] != 'true'

    # For all other cases in production, validate the attachment
    return true if Rails.env.production?

    # In development/test, only validate for approved proofs
    return true if status_approved?

    # For rejected proofs in non-production, be more lenient
    return false if status_rejected? && Rails.env.local?

    # Default to validating
    true
  end

  def proof_must_be_attached
    proof = case proof_type
            when 'income' then application&.income_proof
            when 'residency' then application&.residency_proof
            end
    errors.add(:base, "No #{proof_type} proof found for review") unless proof&.attached?
  end

  def handle_post_review_actions
    log_initial_status
    return if status.blank?

    begin
      process_rejection_flow
      send_status_notification
    rescue StandardError => e
      Rails.logger.error "Failed to process proof review actions: #{e.message}\n#{e.backtrace.join("\n")}"
      raise
    end
  end

  def log_initial_status
    Rails.logger.info "Starting handle_post_review_actions for ProofReview ID: #{id}"
    Rails.logger.info "Initial status check - status: #{status.inspect}, blank?: #{status.blank?}"
    return if status.blank?

    Rails.logger.info "Processing proof review for Application ID: #{application.id}"
    Rails.logger.info "Status details: raw: #{status.inspect}, before type cast: #{status_before_type_cast.inspect}, rejected?: #{status_rejected?}"
  end

  def process_rejection_flow
    ActiveRecord::Base.transaction do
      if status_rejected?
        Rails.logger.info 'Status is rejected, handling rejection flow'
        increment_rejections_if_rejected
        check_max_rejections
      else
        Rails.logger.info 'Status is approved, skipping rejection flow'
      end
    end
  end

  def send_status_notification
    # Skip notifications if this is a paper application context
    # Paper applications handle their own notifications in PaperApplicationService
    return if Current.paper_context

    # Skip if associations aren't loaded properly
    return unless application&.user.present? && admin.present?

    if status_rejected?
      send_notification('proof_rejected', :proof_rejected,
                        { proof_type: proof_type, rejection_reason: rejection_reason })
    else
      send_notification('proof_approved', :proof_approved, { proof_type: proof_type })
    end
  end

  # Creates a notification record and sends the email using the new NotificationService
  # Notification failures don't interrupt the proof review process
  def send_notification(action_name, _mail_method, metadata)
    # Log the audit event - EventDeduplicationService will handle preventing duplicates in audit log display
    AuditEventService.log(
      action: action_name,
      actor: admin,
      auditable: application,
      metadata: metadata
    )

    # Send the notification with Application as notifiable to maintain consistency
    # with existing queries that filter by notifiable_type: 'Application'
    NotificationService.create_and_deliver!(
      type: action_name,
      recipient: application.user,
      actor: admin,
      notifiable: application,
      metadata: metadata,
      channel: :email
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send #{action_name} notification via NotificationService: #{e.message}"
    # Don't re-raise - notification errors shouldn't fail the whole operation
  end

  def increment_rejections_if_rejected
    application.with_lock do
      application.total_rejections += 1
      application.save!
    end
  rescue StandardError => e
    errors.add(:base, "Failed to update rejection count. Please try again. Status: #{e.message}")
    raise ActiveRecord::Rollback
  end

  def check_max_rejections
    application.with_lock do
      send_max_rejections_warning if application.total_rejections >= 8
      archive_application_if_exceeded if application.total_rejections > 8
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process max rejections: #{e.message}"
    errors.add(:base, 'Failed to process rejection limits')
    raise ActiveRecord::Rollback
  end

  def send_max_rejections_warning
    # Log the audit event - EventDeduplicationService will handle preventing duplicates in audit log display
    AuditEventService.log(
      action: 'max_rejections_warning',
      actor: admin,
      auditable: application,
      metadata: { recipient_id: User.admins.first.id }
    )

    # Send the notification
    NotificationService.create_and_deliver!(
      type: 'max_rejections_warning',
      recipient: User.admins.first,
      actor: admin,
      notifiable: application,
      channel: :email
    )
  end

  def archive_application_if_exceeded
    application.update!(status: :archived)
    ApplicationNotificationsMailer.max_rejections_reached(application).deliver_later
  end

  def check_all_proofs_approved
    # Reload the application to ensure we have the latest status
    application.reload

    # Check if required proofs are approved (policy-aware) and certification not already requested
    if application.required_proofs_for_dcf_approved? && application.medical_certification_status_not_requested?
      Rails.logger.info "Required proofs approved for Application ID: #{application.id}, transitioning to awaiting_dcf and requesting medical certification"

      # Update certification status, application status, and send email
      application.with_lock do
        application.update!(
          medical_certification_status: :requested,
          status: :awaiting_dcf
        )
        # Use deliver_later to enqueue a job
        MedicalProviderMailer.request_certification(application).deliver_later
      end
    end
  rescue StandardError => e
    Rails.logger.error "Failed to process required proofs approved: #{e.message}\n#{e.backtrace.join("\n")}"
  end

  def admin_must_be_admin_type
    errors.add(:admin, 'must be an administrator') unless admin&.admin?
  end
end
