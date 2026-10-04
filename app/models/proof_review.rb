# frozen_string_literal: true

# Admin review of an income, residency, or ID proof.
# Medical certification reviews also use this model, but skip its rejection and notification side effects.
class ProofReview < ApplicationRecord
  belongs_to :application
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, class_name: 'User'

  enum :proof_type, { income: 0, residency: 1, medical_certification: 2, id: 3 }, prefix: true
  enum :status, { approved: 0, rejected: 1 }, prefix: true
  enum :submission_method, { web: 0, email: 1, scanned: 2, paper: 3, secure_form: 4 }, prefix: true

  REVIEWABLE_PROOF_TYPES = %w[income id residency].freeze

  def self.reviewable_proof_types
    REVIEWABLE_PROOF_TYPES
  end

  def self.reviewable_proof_type?(proof_type)
    REVIEWABLE_PROOF_TYPES.include?(proof_type.to_s)
  end

  validates :proof_type, presence: true
  validates :status, presence: true
  validates :reviewed_at, presence: true
  validates :rejection_reason, presence: true, if: :status_rejected?
  validate :application_must_be_active
  validate :proof_must_be_attached, if: :should_validate_proof_attachment?
  validate :admin_must_be_admin_type

  before_validation :set_reviewed_at, on: :create
  after_commit :handle_post_review_actions, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :by_admin, ->(admin_id) { where(admin_id: admin_id) }
  scope :rejections, -> { where(status: :rejected) }
  scope :last_3_days, -> { where('created_at > ?', 3.days.ago) }

  def apply_repeat_rejection_side_effects!
    return if proof_type_medical_certification?
    return unless status_rejected?

    ActiveRecord::Base.transaction do
      increment_rejections_if_rejected
      check_max_rejections
    end

    log_rejection_audit_event
    issue_proof_resubmission_form
  end

  private

  def set_reviewed_at
    self.reviewed_at ||= Time.current
  end

  def application_must_be_active
    errors.add(:application, 'cannot be reviewed when archived') if application&.status_archived?
  end

  def should_validate_proof_attachment?
    # A rejected medical certification or paper proof can have no attachment, in all environments.
    return false if status_rejected? && proof_type_medical_certification?
    return false if status_rejected? && submission_method_paper?

    # Tests skip this validation unless VALIDATE_PROOF_ATTACHMENTS=true.
    return false if Rails.env.test? && ENV['VALIDATE_PROOF_ATTACHMENTS'] != 'true'
    return true if Rails.env.production?
    return true if status_approved?

    # Development and test accept a rejection with no attachment. Other non-production environments do not.
    return false if status_rejected? && Rails.env.local?

    true
  end

  def proof_must_be_attached
    proof = case proof_type
            when 'income' then application&.income_proof
            when 'residency' then application&.residency_proof
            when 'id' then application&.id_proof
            when 'medical_certification' then application&.medical_certification
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
    Rails.logger.debug { "Starting handle_post_review_actions for ProofReview ID: #{id}" }
    Rails.logger.debug { "Initial status check - status: #{status.inspect}, blank?: #{status.blank?}" }
    return if status.blank?

    Rails.logger.debug { "Processing proof review for Application ID: #{application.id}" }
    Rails.logger.debug do
      "Status details: raw: #{status.inspect}, before type cast: #{status_before_type_cast.inspect}, rejected?: #{status_rejected?}"
    end
  end

  def process_rejection_flow
    return if proof_type_medical_certification?

    ActiveRecord::Base.transaction do
      if status_rejected?
        Rails.logger.debug 'Status is rejected, handling rejection flow'
        increment_rejections_if_rejected
        check_max_rejections
      else
        Rails.logger.debug 'Status is approved, skipping rejection flow'
      end
    end
  end

  def send_status_notification
    # Medical certification reviews have their own provider notification flow.
    return if proof_type_medical_certification?

    # Skip when the applicant or the admin record is missing.
    return unless application&.user.present? && admin.present?

    status_rejected? ? request_proof_resubmission : send_approval_notification
  end

  def request_proof_resubmission
    log_rejection_audit_event
    issue_proof_resubmission_form
  end

  def issue_proof_resubmission_form
    result = Applications::RequestProofResubmission.new(
      application: application,
      actor: admin,
      proof_type: proof_type.to_sym
    ).call
    return unless result.failure?

    Rails.logger.warn("Proof resubmission request failed for ProofReview #{id}: #{result.message}")
    log_resubmission_request_failure(result.message, delivery_suppressed: result.data.is_a?(Hash) && result.data[:delivery_suppressed])
  rescue StandardError => e
    Rails.logger.error "Failed to request proof resubmission: #{e.message}"
    log_resubmission_request_failure(e.class.name)
  end

  # The rejection stands when its secure link cannot be sent. This audit event lets staff follow up.
  # This method does not try a different recipient.
  # delivery_suppressed means that the email controls stopped the email on purpose. It is not a delivery failure.
  def log_resubmission_request_failure(reason, delivery_suppressed: false)
    AuditEventService.log(
      action: 'proof_resubmission_request_failed',
      actor: admin,
      auditable: application,
      metadata: { proof_type: proof_type, proof_review_id: id, reason: reason.to_s,
                  delivery_suppressed: delivery_suppressed.presence }.compact
    )
  rescue StandardError => e
    Rails.logger.error "Failed to record proof resubmission request failure: #{e.message}"
  end

  def log_rejection_audit_event
    AuditEventService.log(
      action: 'proof_rejected',
      actor: admin,
      auditable: application,
      metadata: {
        proof_type: proof_type,
        rejection_reason: rejection_reason,
        submission_method: submission_method,
        rejection_reason_code: rejection_reason_code
      }.compact
    )
  end

  # Records a notification for Recent Notifications, but sends no email or letter.
  # Constituents see the proof status in the portal. Staff see the audit event.
  def send_approval_notification
    AuditEventService.log(
      action: 'proof_approved',
      actor: admin,
      auditable: application,
      metadata: { proof_type: proof_type }
    )

    # Queries filter on notifiable_type: 'Application', so the notifiable must be the application.
    NotificationService.create_and_deliver!(
      type: 'proof_approved',
      recipient: proof_approval_recipient,
      actor: admin,
      notifiable: application,
      metadata: { proof_type: proof_type },
      channel: :email,
      deliver: false
    )
  rescue StandardError => e
    Rails.logger.error "Failed to send proof_approved notification via NotificationService: #{e.message}"
    # A notification error must not fail the review.
  end

  def proof_approval_recipient
    resolver = Applications::SecureRequestRecipientResolver.new(application: application)
    default_recipient_id = resolver.default_recipient_ids.first

    resolver.known_recipients.find { |recipient| recipient.id == default_recipient_id } || application.user
  end

  def increment_rejections_if_rejected
    application.with_lock do
      application.total_rejections += 1
      application.save!
    end
  rescue StandardError => e
    Rails.logger.error "ProofReview#increment_rejections_if_rejected failed for application #{application.id}: #{e.class} #{e.message}"
    errors.add(:base, "Failed to update rejection count. Please try again. Status: #{e.message}")
    raise ActiveRecord::Rollback
  end

  def check_max_rejections
    application.with_lock do
      send_max_rejections_warning if application.total_rejections >= 8
      archive_application_if_exceeded if application.total_rejections > 8
    end
  rescue StandardError => e
    Rails.logger.error "ProofReview#check_max_rejections failed for application #{application.id}: #{e.class} #{e.message}"
    errors.add(:base, 'Failed to process rejection limits')
    raise ActiveRecord::Rollback
  end

  def send_max_rejections_warning
    # Each rejection at a total of 8 or more logs and sends a new warning.
    # Audit displays merge duplicates only within one 1-minute bucket (EventDeduplicationService).
    AuditEventService.log(
      action: 'max_rejections_warning',
      actor: admin,
      auditable: application,
      metadata: { recipient_id: User.admins.first.id }
    )

    NotificationService.create_and_deliver!(
      type: 'max_rejections_warning',
      recipient: User.admins.first,
      actor: admin,
      notifiable: application,
      channel: :email
    )
  end

  def archive_application_if_exceeded
    application.transition_status!(
      :archived,
      actor: admin,
      notes: 'Application archived after exceeding maximum proof rejections',
      metadata: { trigger: 'max_proof_rejections' }
    )
    ApplicationNotificationsMailer.max_rejections_reached(application).deliver_later
  end

  def admin_must_be_admin_type
    errors.add(:admin, 'must be an administrator') unless admin&.admin?
  end
end
