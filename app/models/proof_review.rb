# frozen_string_literal: true

# Admin review of an income, residency, or ID proof.
# Disability certification reviews also use this model. A decision's follow-up (notices, audit, secure resubmission
# request) is Applications::ProofDecisionFollowUp, scheduled by the writer that records it.
class ProofReview < ApplicationRecord
  class DecisionConflict < StandardError; end
  Decision = Data.define(:review, :recorded)

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
  validates :decision_key, :decision_fingerprint, presence: true
  validates :rejection_reason, presence: true, if: :status_rejected?
  validate :application_must_be_active, on: :create
  validate :proof_must_be_attached, unless: :attachment_optional?, on: :create
  validate :admin_must_be_admin_type

  before_validation :set_reviewed_at, on: :create

  scope :chronological, -> { order(reviewed_at: :asc, id: :asc) }
  scope :recent, -> { chronological.reverse_order }
  scope :by_admin, ->(admin_id) { where(admin_id: admin_id) }
  scope :rejections, -> { where(status: :rejected) }
  scope :last_3_days, -> { where('reviewed_at > ?', 3.days.ago) }

  # A rejection recorded because no document came with the application, not because a document was found wanting.
  def none_provided?
    status_rejected? && rejection_reason_code == 'none_provided'
  end

  def current_rejection?(application: self.application)
    status_rejected? && application.id == application_id &&
      application.public_send("#{document_type.attachment_name}_status") == 'rejected' &&
      application.proof_reviews.where(proof_type: proof_type).recent.pick(:id) == id
  end

  # Resolve retries before checking today's attachment or reviewability. Only a new decision enters the writer.
  # The submitted target remains an identifier even after a rejected blob has been purged.
  def self.record_decision!(application:, decision_key:, reviewed_blob_id:, proof_type:, status:, admin:, # rubocop:disable Metrics/ParameterLists
                            rejection_reason: nil, rejection_reason_code: nil, notes: nil)
    raise DecisionConflict, 'Reload this application before submitting a review.' if decision_key.blank?

    target_id = reviewed_target_id(reviewed_blob_id)

    attributes = {
      proof_type: proof_type.to_s, status: status.to_s, admin: admin, reviewed_blob_id: target_id,
      rejection_reason: status.to_s == 'rejected' ? rejection_reason.to_s.presence : nil,
      rejection_reason_code: status.to_s == 'rejected' ? rejection_reason_code.to_s.presence : nil,
      notes: notes.to_s.presence
    }
    fingerprint = Digest::SHA256.hexdigest([
      attributes[:proof_type], attributes[:status], admin&.id, target_id,
      attributes[:rejection_reason], attributes[:rejection_reason_code], attributes[:notes]
    ].to_json)

    application.with_lock do
      existing = application.proof_reviews.find_by(decision_key: decision_key)
      if existing
        raise DecisionConflict, 'This review was already submitted with different details. Reload this application.' unless existing.decision_fingerprint == fingerprint

        Decision.new(review: existing, recorded: false)
      else
        current_blob_id = application.document_attachment_for(proof_type).blob&.id
        raise DecisionConflict, 'The document changed after this review was opened. Reload this application.' unless current_blob_id == target_id

        review = application.proof_reviews.new(**attributes, decision_key: decision_key, decision_fingerprint: fingerprint)
        review.instance_variable_set(:@recording_decision, true)
        yield review
        raise ArgumentError, 'The proof decision writer did not record its review' unless review.persisted?

        Decision.new(review: review, recorded: true)
      end
    end
  end

  def self.reviewed_target_id(value)
    return if value.blank?

    Integer(value.to_s, exception: false) || raise(DecisionConflict, 'The reviewed document is invalid. Reload this application.')
  end
  private_class_method :reviewed_target_id

  # Internal insert for record_decision!'s writer block. Existing decisions cannot be changed or counted again.
  def record!(**attributes)
    raise ArgumentError, 'Use ProofReview.record_decision! to record a new decision' unless @recording_decision && new_record?

    @rejection_total = nil
    assign_attributes(attributes)
    transaction do
      # The insert takes a shared lock on the application row for the foreign key. Two rejections that each
      # held it would deadlock asking for the exclusive lock, so the exclusive lock comes first.
      application.lock! if counts_toward_rejection_limit?
      save!
      count_rejection! if counts_toward_rejection_limit?
    end
    self
  end

  def readonly?
    persisted? || super
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
