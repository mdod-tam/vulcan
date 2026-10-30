# frozen_string_literal: true

# Admin review of an income, residency, or ID proof.
# Disability certification reviews also use this model. A decision's follow-up (notices, audit, secure resubmission
# request) is Applications::ProofDecisionFollowUp, scheduled by the writer that records it.
class ProofReview < ApplicationRecord
  belongs_to :application
  belongs_to :admin, -> { where(type: 'Users::Administrator') }, class_name: 'User'

  enum :proof_type, { income: 0, residency: 1, disability_certification: 2, id: 3 }, prefix: true
  enum :status, { approved: 0, rejected: 1 }, prefix: true
  enum :submission_method, { web: 0, email: 1, scanned: 2, paper: 3, secure_form: 4 }, prefix: true

  REVIEWABLE_PROOF_TYPES = %w[income id residency].freeze

  # The rejection that reaches this total sends a warning. A rejection past it archives the application.
  MAX_REJECTIONS = 8

  # The application's rejection total after the rejection this instance recorded; nil for any other decision.
  attr_reader :rejection_total

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
  validate :proof_must_be_attached, unless: :attachment_optional?
  validate :admin_must_be_admin_type

  before_validation :set_reviewed_at, on: :create

  scope :recent, -> { order(created_at: :desc) }
  scope :by_admin, ->(admin_id) { where(admin_id: admin_id) }
  scope :rejections, -> { where(status: :rejected) }
  scope :last_3_days, -> { where('created_at > ?', 3.days.ago) }

  # The row for one decision on an application. A proof type and a status keep a single row between them,
  # so a repeat decision updates that row instead of adding another.
  def self.for_decision(application, proof_type:, status:)
    application.proof_reviews.find_or_initialize_by(proof_type: proof_type, status: status)
  end

  # Saves the decision. A new row stamps reviewed_at when it is created; a repeat decision stamps it here.
  # A rejection is counted, and the application archived once it passes the limit, in the same transaction
  # as the decision. If that fails, the decision rolls back with it.
  def record!(**attributes)
    @rejection_total = nil
    assign_attributes(attributes)
    self.reviewed_at = Time.current unless new_record?
    transaction do
      # The insert takes a shared lock on the application row for the foreign key. Two rejections that each
      # held it would deadlock asking for the exclusive lock, so the exclusive lock comes first.
      application.lock! if counts_toward_rejection_limit?
      save!
      count_rejection! if counts_toward_rejection_limit?
    end
    self
  end

  # The review committed and a later step failed. This event lets staff find the review and check it.
  def log_follow_up_failure(error)
    AuditEventService.log(
      action: 'proof_review_follow_up_failed',
      actor: admin,
      auditable: application,
      metadata: { proof_review_id: id, proof_type: proof_type, error_class: error.class.name }
    )
  rescue StandardError => e
    Rails.logger.error "Could not record proof review follow-up failure for Application #{application_id}: #{e.class.name}"
  end

  private

  def set_reviewed_at
    self.reviewed_at ||= Time.current
  end

  def document_type
    DocumentType.fetch(proof_type) if proof_type.present?
  end

  def application_must_be_active
    errors.add(:application, 'cannot be reviewed when archived') if application&.status_archived?
  end

  # A rejected paper proof, or a document that can be rejected without a file, can have no attachment.
  def attachment_optional?
    status_rejected? && (document_type&.rejectable_without_file || submission_method_paper?)
  end

  def proof_must_be_attached
    return if proof_type.blank? # The presence validation reports it.

    proof = application&.document_attachment_for(proof_type)
    errors.add(:base, "No #{proof_type} proof found for review") unless proof&.attached?
  end

  # A disability certification rejection has its own flow and does not count toward the limit.
  def counts_toward_rejection_limit?
    status_rejected? && document_type&.counts_toward_rejection_limit
  end

  # Runs inside record!'s transaction under the application lock it took, so an error rolls the decision back.
  # The total is kept for the notices, which wait for the commit.
  def count_rejection!
    application.update!(total_rejections: application.total_rejections + 1)
    @rejection_total = application.total_rejections
    archive_application_if_exceeded if @rejection_total > MAX_REJECTIONS
  end

  def archive_application_if_exceeded
    application.transition_status!(
      :archived,
      actor: admin,
      notes: 'Application archived after exceeding maximum proof rejections',
      metadata: { trigger: 'max_proof_rejections' }
    )
  end

  def admin_must_be_admin_type
    errors.add(:admin, 'must be an administrator') unless admin&.admin?
  end
end
