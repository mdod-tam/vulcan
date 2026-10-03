# frozen_string_literal: true

# Owns application lifecycle rules for proofs, certification, training, evaluations, and fulfillment.
class Application < ApplicationRecord
  has_many :email_delivery_attempts, dependent: :nullify
  MedicalProviderInfo = Struct.new(:name, :phone, :fax, :email, keyword_init: true) do # rubocop:disable Style/RedundantStructKeywordInit
    def present?
      name.present? || phone.present? || fax.present? || email.present?
    end

    def valid_phone?
      phone.present? && phone.match?(/\A[\d\-()\s.]+\z/)
    end

    def valid_email?
      email.present? && email.match?(/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/)
    end
  end

  ProofResult = Struct.new(:success, :type, :message, :error, keyword_init: true) do # rubocop:disable Style/RedundantStructKeywordInit
    def success?
      success == true
    end

    def error_message
      error&.message || message
    end
  end

  # Signing URLs require encryption at rest because they can expose document or audit data.
  encrypts :document_signing_audit_url
  encrypts :document_signing_document_url

  include ApplicationStatusManagement
  include ApplicationSubmissionEligibility
  include NotificationDelivery
  include ProofManageable
  include ProofConsistencyValidation
  include ApplicationProviderInfoRequests
  include CertificationManagement
  include VoucherManagement
  include TrainingManagement
  include EvaluationManagement
  include ContactChangeAudit

  # The nested provider form uses this virtual attribute.
  attr_accessor :medical_provider_attributes

  enum :status, {
    draft: 0,               # Incomplete application
    in_progress: 1,         # Submitted for processing
    approved: 2,
    rejected: 3,
    awaiting_proof: 4,
    reminder_sent: 5,
    awaiting_dcf: 6,        # Disability certification form (DCF) pending
    archived: 7
  }, prefix: true, validate: true

  enum :fulfillment_type, { equipment: 0, voucher: 1 }, prefix: true

  enum :income_proof_status, {
    not_reviewed: 0,
    approved: 1,
    rejected: 2
  }, prefix: true

  enum :residency_proof_status, {
    not_reviewed: 0,
    approved: 1,
    rejected: 2
  }, prefix: true

  enum :id_proof_status, {
    not_reviewed: 0,
    approved: 1,
    rejected: 2
  }, prefix: true

  enum :medical_certification_status, {
    not_requested: 0,
    requested: 1,
    received: 2,
    approved: 3,
    rejected: 4
  }, prefix: :medical_certification_status

  enum :document_signing_status, {
    not_sent: 0,
    sent: 1,
    opened: 2,
    signed: 3,
    declined: 4
  }, prefix: :document_signing_status

  # Accept both constituent STI names.
  belongs_to :user, -> { where("type = 'Users::Constituent' OR type = 'Constituent'") },
             class_name: 'User',
             foreign_key: :user_id,
             inverse_of: :applications
  belongs_to :income_verified_by,
             class_name: 'User',
             optional: true,
             inverse_of: :income_verified_applications
  belongs_to :managing_guardian,
             class_name: 'User',
             optional: true,
             inverse_of: :managed_applications
  belongs_to :medical_certification_verified_by,
             class_name: 'User',
             optional: true

  has_many :training_sessions, class_name: 'TrainingSession', dependent: :destroy
  has_many :trainers, through: :training_sessions
  has_many :evaluations, dependent: :destroy
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_many :proof_reviews, dependent: :destroy
  has_many :status_changes, class_name: 'ApplicationStatusChange', dependent: :destroy
  has_many :events, as: :auditable, dependent: :destroy
  has_many :vouchers, dependent: :restrict_with_error
  has_many :application_notes, dependent: :destroy
  has_many :medical_provider_secure_request_forms, dependent: :destroy
  has_and_belongs_to_many :products
  has_one_attached :income_proof
  has_one_attached :residency_proof
  has_one_attached :id_proof
  has_one_attached :medical_certification
  # Retain late DocuSeal or secure-upload submissions when certification is received or approved,
  # or when the request predates rejection.
  has_many_attached :additional_medical_certifications

  validates :application_date, presence: true
  validates :status, presence: true
  validates :maryland_resident, inclusion: { in: [true], message: 'You must be a Maryland resident to apply' }, unless: :status_draft?
  validates :terms_accepted, acceptance: { accept: true }, if: :submitted?
  validates :information_verified, acceptance: { accept: true }, if: :submitted?
  validates :medical_release_authorized, acceptance: { accept: true }, if: -> { submitted? && !skip_medical_provider_validation? }
  validates :medical_provider_name, presence: true, unless: :skip_medical_provider_validation?
  validates :medical_provider_phone, presence: true, unless: :skip_medical_provider_validation?
  validates :medical_provider_email, presence: true, unless: :skip_medical_provider_validation?
  validates :self_certify_disability, inclusion: { in: [true, false] }, unless: :status_draft?
  validates :alternate_contact_phone,
            format: { with: /\A\+?[\d\-()\s]+\z/, allow_blank: true }
  validates :alternate_contact_email,
            format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }
  validate :waiting_period_completed, on: :create
  validate :constituent_must_have_disability, if: :validate_disability?
  validate :managing_guardian_cannot_be_applicant

  delegate :present?, to: :active_training_session, prefix: true

  before_validation :scrub_income_fields, if: :should_scrub_income?
  before_save :ensure_managing_guardian_set, if: :user_id_changed?
  before_create :stamp_workflow_defaults!
  before_create :ensure_managing_guardian_set
  after_update :reconcile_pending_letters_after_owner_change

  # Scopes
  scope :draft, -> { where(status: :draft) }
  scope :search_by_last_name, lambda { |query|
    includes(:user, :proof_reviews, :training_sessions, :evaluations)
      .where('users.last_name ILIKE ?', "%#{query}%")
      .references(:users)
  }

  scope :draft_for_constituent, lambda { |user_id|
    draft.where(user_id: user_id)
  }

  scope :active_for_constituent, lambda { |user_id|
    where(user_id: user_id)
      .where.not(status: %i[draft archived rejected])
  }

  # Archived and rejected records do not block submission through this scope.
  scope :blocking_new_submission, -> { where.not(status: %i[archived rejected]) }

  scope :managed_by, lambda { |guardian_user|
    where(managing_guardian_id: guardian_user.id)
  }

  scope :for_dependents_of, lambda { |guardian_user|
    if guardian_user
      joins('INNER JOIN guardian_relationships ON applications.user_id = guardian_relationships.dependent_id')
        .where(guardian_relationships: { guardian_id: guardian_user.id })
    else
      none
    end
  }

  # Includes dependent applications managed by other guardians. Use for viewing, not edit authorization.
  scope :related_to_guardian, lambda { |guardian_user|
    managed_by(guardian_user)
      .or(for_dependents_of(guardian_user))
  }

  # Ownership permits edits for an unmanaged applicant or the managing guardian.
  # Callers must also require draft status before allowing an edit.
  scope :editable_by, lambda { |user|
    where('(applications.user_id = :user_id AND applications.managing_guardian_id IS NULL)
           OR applications.managing_guardian_id = :user_id', user_id: user.id)
  }

  # Viewing uses the same ownership boundary as editing.
  scope :accessible_by, lambda { |user|
    editable_by(user)
  }

  # Completion requires a submitted application, approved income/residency proofs, and at least one voucher, all redeemed.
  scope :complete, lambda {
    where.not(status: :draft)
         .where(residency_proof_status: :approved)
         .where(income_proof_status: :approved)
         .joins(:vouchers)
         .where(
           'NOT EXISTS (SELECT 1 FROM vouchers v WHERE v.application_id = applications.id AND v.status != ?)',
           Voucher.statuses[:redeemed]
         )
         .distinct # Multiple vouchers must not duplicate an application.
  }

  scope :with_proofs_needing_review, lambda {
    where(
      'residency_proof_status = :nr OR id_proof_status = :nr OR (income_proof_required = TRUE AND income_proof_status = :nr)',
      nr: residency_proof_statuses[:not_reviewed]
    )
  }

  scope :with_pending_training_request, lambda {
    where(status: :approved)
      .where.not(training_requested_at: nil)
      .where.not(id: TrainingSession.assigned_or_scheduled.select(:application_id))
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1
          FROM training_sessions
          WHERE training_sessions.application_id = applications.id
            AND training_sessions.created_at >= applications.training_requested_at
        )
      SQL
  }

  # An explicit request timestamp drives this queue. Fulfillment type alone does not create a request.
  # An evaluation created at or after the request closes it, regardless of evaluation status.
  scope :with_pending_evaluation_request, lambda {
    where(status: :approved)
      .where.not(evaluation_requested_at: nil)
      .where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1
          FROM evaluations
          WHERE evaluations.application_id = applications.id
            AND evaluations.created_at >= applications.evaluation_requested_at
        )
      SQL
  }

  scope :with_pending_training, lambda {
    joins(:training_sessions).merge(TrainingSession.where(status: %i[requested scheduled confirmed])).distinct
  }

  scope :with_active_training_for_trainer, lambda { |trainer_id|
    joins(:training_sessions).where(
      training_sessions: {
        trainer_id: trainer_id,
        status: %i[scheduled confirmed]
      }
    ).distinct
  }

  # Attachment preloads
  # Preload income, residency, and medical certification attachments with their blobs.
  # Active Storage uses separate preload queries. Use with a relation or a single-record finder:
  #   Application.with_proof_blobs.includes(:user).page(params[:page])
  scope :with_proof_blobs, lambda {
    with_attached_income_proof
      .with_attached_residency_proof
      .with_attached_medical_certification
  }

  scope :digitally_signed_needs_review, lambda {
    where(document_signing_status: :signed)
      .where.not(status: %i[rejected archived])
      .where.not(medical_certification_status: %i[approved rejected])
  }

  def self.pain_point_analysis
    draft
      .where.not(last_visited_step: [nil, ''])
      .group(:last_visited_step)
      .order(count_all: :desc)
      .count
  end

  def self.expire_training_request_metrics_cache!
    Rails.cache.delete('admin_dashboard_metrics')
    Rails.cache.delete('dashboard_metrics_training_requests')
  rescue StandardError => e
    Rails.logger.warn "[Application] Cache expiry failed (non-fatal): #{e.message}"
  end

  def self.batch_update_status(ids, new_status, actor:) # rubocop:disable Metrics/PerceivedComplexity
    return { success: false, success_count: 0, errors: ['No applications selected'] } if ids.blank?

    success_count = 0
    errors = []

    transaction do
      applications = where(id: ids)
      found_ids = applications.pluck(:id).map(&:to_s)
      missing_ids = ids.map(&:to_s) - found_ids

      errors << "Applications not found: #{missing_ids.join(', ')}" if missing_ids.any?

      applications.find_each do |application|
        success = if new_status.to_sym == :approved
                    application.approve!(user: actor)
                  elsif new_status.to_sym == :rejected
                    application.reject!(user: actor)
                  else
                    application.transition_status!(new_status, actor: actor, metadata: { trigger: 'batch_update' })
                  end

        if success
          success_count += 1
        else
          errors << "Application ##{application.id} failed to update"
        end
      rescue StandardError => e
        errors << "Application ##{application.id}: #{e.message}"
      end

      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      { success: false, success_count: 0, errors: errors }
    else
      { success: true, success_count: success_count, errors: [] }
    end
  end

  # Instance methods
  def skip_medical_provider_validation?
    status_draft? ||
      status_awaiting_proof? ||
      ((status_awaiting_dcf? || medical_certification_status_approved?) && missing_required_provider_info?)
  end

  def missing_required_provider_info?
    %i[medical_provider_name medical_provider_phone medical_provider_email].any? do |attribute|
      public_send(attribute).blank?
    end
  end

  def medical_provider_info_present?
    %i[medical_provider_name medical_provider_phone medical_provider_fax medical_provider_email].any? do |attribute|
      public_send(attribute).present?
    end
  end

  def ready_for_docuseal?
    medical_provider_name.present? && medical_provider_email.present?
  end

  def approve!(user:)
    Applications::Approver.new(self, by: user).call
  end

  def reject!(user:)
    Applications::Rejecter.new(self, by: user).call
  end

  def request_documents!(user:)
    Applications::DocumentRequester.new(self, by: user).call
  end

  def submit!(actor:)
    transition_status!(
      :in_progress,
      actor: actor,
      metadata: { trigger: 'submission' }
    )
  end

  # Change status and its history in one transaction with audit logging.
  # An audit exception propagates and rolls back the status change.
  def transition_status!(new_status, actor:, notes: nil, metadata: {})
    raise ArgumentError, 'actor is required' if actor.blank?

    with_lock do
      old_status = status
      target_status = new_status.to_s

      return true if old_status == target_status

      update!(status: target_status)

      status_changes.create!(
        from_status: old_status,
        to_status: status,
        user: actor,
        notes: notes,
        metadata: metadata.reverse_merge(
          application_id: id,
          old_status: old_status,
          new_status: status,
          submission_method: submission_method,
          notes: notes
        )
      )

      AuditEventService.log(
        action: 'application_status_changed',
        actor: actor,
        auditable: self,
        metadata: metadata.reverse_merge(
          application_id: id,
          old_status: old_status,
          new_status: status,
          submission_method: submission_method,
          notes: notes
        )
      )

      if target_status == 'approved' && voucher_fulfillment?
        assignment_method = metadata[:trigger].to_s == 'auto_approval' ? 'automatic' : 'manual_approval'
        IssueInitialVoucherJob.perform_later(id, actor.id, assignment_method)
      end

      true
    end
  end

  def constituent_full_name
    if user && (user.first_name || user.last_name)
      "#{user.first_name} #{user.last_name}".strip
    else
      'Unknown Constituent'
    end
  end

  # A submission event newer than the latest review requires another review.
  # @param proof_type [String] The proof type ("income", "residency", or "id")
  # @return [Boolean] True for a submission with no review or one newer than the latest review
  def needs_proof_type_review?(proof_type)
    latest_review, latest_audit = latest_review_and_audit(proof_type)

    return true if latest_review.nil? && latest_audit.present?

    latest_audit.present? && latest_review.present? && latest_audit.created_at > latest_review.created_at
  end

  def proof_review_state(proof_type)
    proof_type = proof_type.to_s
    return :not_applicable unless ProofReview.reviewable_proof_type?(proof_type)
    return :not_applicable if proof_type == 'income' && !income_proof_required?

    attachment = public_send("#{proof_type}_proof")
    return :missing_attachment unless attachment.attached?

    if public_send("#{proof_type}_proof_status_approved?")
      return needs_proof_type_review?(proof_type) ? :resubmitted : :approved_current
    end

    return :rejected if public_send("#{proof_type}_proof_status_rejected?")
    return :pending if public_send("#{proof_type}_proof_status_not_reviewed?")

    :pending
  end

  def proof_type_reviewable?(proof_type)
    proof_review_state(proof_type).in?(%i[pending rejected resubmitted])
  end

  def proofs_reviewable?
    %w[income id residency].any? { |proof_type| proof_type_reviewable?(proof_type) }
  end

  def proof_review_button_text(proof_type)
    case proof_review_state(proof_type)
    when :resubmitted
      'Review Resubmitted Proof'
    when :rejected
      'Review Rejected Proof'
    else
      'Review Proof'
    end
  end

  def proof_review_button_class(proof_type)
    proof_review_state(proof_type) == :rejected ? 'bg-red-600 hover:bg-red-700' : 'bg-blue-600 hover:bg-blue-700'
  end

  # @param proof_type [String] The proof type ("income", "residency", or "id")
  # @return [Array] The latest review and submission audit event, in that order
  def latest_review_and_audit(proof_type)
    latest_review = proof_reviews.where(proof_type: proof_type).order(created_at: :desc).first
    latest_audit = latest_proof_submission_event(proof_type)

    [latest_review, latest_audit]
  end

  def latest_proof_submission_event(proof_type)
    proof_type = proof_type.to_s
    events
      .where(
        "(action = :generic_action AND metadata->>'proof_type' = :proof_type) OR action IN (:legacy_actions)",
        generic_action: 'proof_submitted',
        proof_type: proof_type,
        legacy_actions: ["#{proof_type}_proof_submitted", "#{proof_type}_proof_attached"]
      )
      .order(created_at: :desc)
      .first
  end

  def medical_provider_name
    self[:medical_provider_name]
  end

  def for_dependent?
    managing_guardian_id.present?
  end

  # Admin fulfillment responsibility

  def admin_fulfillment_responsibility_state
    return :voucher_no_equipment if voucher_fulfillment?

    return :pending_evaluation unless evaluations.completed_sessions.any?

    if equipment_po_sent_at.present?
      :po_sent
    elsif equipment_bids_sent_at.present?
      :bids_sent
    else
      :needs_action
    end
  end

  def mark_equipment_bids_sent!(date:, actor:)
    update!(equipment_bids_sent_at: date)
    AuditEventService.log(
      action: 'equipment_bids_sent',
      actor: actor,
      auditable: self,
      metadata: { date: date }
    )
  end

  def mark_equipment_po_sent!(date:, actor:)
    update!(equipment_po_sent_at: date)
    AuditEventService.log(
      action: 'equipment_po_sent',
      actor: actor,
      auditable: self,
      metadata: { date: date }
    )
  end

  # Workflow predicates

  def income_collection_enabled?
    if persisted?
      income_proof_required?
    else
      FeatureFlag.income_proof_required?
    end
  end

  def voucher_fulfillment?
    fulfillment_type_voucher?
  end

  def equipment_fulfillment?
    fulfillment_type_equipment?
  end

  def required_proofs_approved?
    residency_proof_status_approved? && id_proof_status_approved? &&
      (!income_proof_required? || income_proof_status_approved?)
  end

  def voucher_issuable?
    can_create_voucher?
  end

  def active_training_session
    training_sessions.assigned_or_scheduled.order(created_at: :desc, id: :desc).first
  end

  def training_request_pending?
    training_requested_at.present? &&
      !active_training_session_present? &&
      training_sessions.where(created_at: training_requested_at..).none?
  end

  # Any evaluation created at or after the request closes it, regardless of evaluation status.
  def evaluation_request_pending?
    evaluation_requested_at.present? &&
      evaluations.where(created_at: evaluation_requested_at..).none?
  end

  def request_evaluation!(actor:)
    raise ArgumentError, 'Evaluation can only be requested on approved applications' unless status_approved?
    raise ArgumentError, 'An evaluation request is already pending' if evaluation_request_pending?

    update!(evaluation_requested_at: Time.current)
    AuditEventService.log(
      action: 'evaluation_requested',
      actor: actor,
      auditable: self,
      metadata: { application_id: id }
    )
  end

  def service_window_active?
    return false unless status_approved?
    return false if application_date.blank?

    end_date = service_window_end_date
    end_date.present? && end_date > Date.current
  end

  # The current waiting_period_years policy sets the service window end. It returns nil when application_date is absent.
  # Eligibility and constituent copy share this calculation.
  def service_window_end_date
    return nil if application_date.blank?

    waiting_period = Policy.get('waiting_period_years') || 3
    application_date.to_date + waiting_period.years
  end

  def guardian_relationship_type
    return nil unless for_dependent?

    GuardianRelationship.find_by(
      guardian_id: managing_guardian_id,
      dependent_id: user_id
    )&.relationship_type
  end

  # Authorization
  def editable_by?(user)
    return false unless user

    is_owner = user_id == user.id && managing_guardian_id.nil?
    is_managing_guardian = managing_guardian_id == user.id

    is_owner || is_managing_guardian
  end

  def accessible_by?(user)
    # Viewing uses the same ownership boundary as editing.
    editable_by?(user)
  end

  def viewable_by?(user)
    accessible_by?(user)
  end

  private

  def reconcile_pending_letters_after_owner_change
    return unless saved_changes.keys.intersect?(PrintQueueItem::APPLICATION_IDENTITY_FIELDS)

    Letters::ReconcilePendingJob.schedule(application_id: id)
  end

  def stamp_workflow_defaults!
    self.fulfillment_type = FeatureFlag.enabled?(:vouchers_enabled) ? :voucher : :equipment
    self.income_proof_required = FeatureFlag.income_proof_required?
  end

  def scrub_income_fields
    self.annual_income = nil
    self.household_size = nil
  end

  def should_scrub_income?
    !income_collection_enabled? && (new_record? || status_draft?)
  end

  def waiting_period_completed
    return if Application.skip_wait_period_validation
    return unless user

    last_app = user_applications_except_current
    return unless last_app

    waiting_period = Policy.get('waiting_period_years') || 3
    return unless last_app.application_date > waiting_period.years.ago

    errors.add(:base, "You must wait #{waiting_period} years before submitting a new application.")
  end

  def user_applications_except_current
    scope = user.applications
    scope = scope.where.not(id: id) unless new_record?
    scope.order(application_date: :desc).first
  end

  def needs_proof_review?
    saved_change_to_needs_review_since? && needs_review_since.present?
  end

  def pending_proof_types
    types = []
    types << 'income' if income_proof_required? && income_proof_status_not_reviewed?
    types << 'id' if id_proof_status_not_reviewed?
    types << 'residency' if residency_proof_status_not_reviewed?
    types
  end

  def constituent_must_have_disability
    return if user&.disability_selected?

    errors.add(:base, 'At least one disability must be selected before submitting an application.')
  end

  def validate_disability?
    return false if status_draft?
    return true if saved_change_to_status? && status_before_last_save == 'draft'
    return true if submitted?

    false
  end

  def managing_guardian_cannot_be_applicant
    return if managing_guardian_id.blank? || user_id.blank?

    return unless managing_guardian_id == user_id

    errors.add(:base, 'An application cannot be managed by the applicant themselves')
  end

  # Assign a guardian before create or after an applicant change when no manager is set.
  # An existing manager takes precedence over relationships.
  def ensure_managing_guardian_set
    return if managing_guardian_id.present? || user_id.blank?

    guardian_relationship = GuardianRelationship.find_by(dependent_id: user_id)

    return unless guardian_relationship

    # Do not assign the applicant as their own guardian.
    return if guardian_relationship.guardian_id == user_id

    Rails.logger.info "Setting managing_guardian_id to #{guardian_relationship.guardian_id} for application #{id}"
    self.managing_guardian_id = guardian_relationship.guardian_id
  end
end
