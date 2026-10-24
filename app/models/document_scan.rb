# frozen_string_literal: true

class DocumentScan < ApplicationRecord
  class NotCleared < StandardError; end
  class LimitExceeded < StandardError; end

  include DocumentScan::Work
  include DocumentScan::Continuation

  RETENTION = 7.days
  PURPOSES = ProofUploadFormats::MAX_SIZES.keys.map(&:to_s).freeze

  belongs_to :blob, class_name: 'ActiveStorage::Blob'
  belongs_to :user, optional: true
  belongs_to :secure_form, polymorphic: true, optional: true
  serialize :context, coder: JSON, type: Hash
  encrypts :context

  enum :status, { pending: 'pending', clean: 'clean', blocked: 'blocked', failed: 'failed' }, validate: true
  validates :purpose, inclusion: { in: PURPOSES }
  validates :slot, presence: true, length: { maximum: 64 }
  validates :form_context, length: { maximum: 100 }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :upload_owner_present, on: :create
  validates :continuation, inclusion: { in: ['docuseal'] }, allow_nil: true

  scope :recoverable, -> { where(dismissed_at: nil, created_at: RETENTION.ago..).where.not(blob_id: ActiveStorage::Attachment.select(:blob_id)) }

  def self.stage!(**attributes)
    DocumentScans::Stager.new(**attributes).call
  end

  # Missing history is deliberately unavailable, including pre-release seed files.
  def self.cleared?(blob)
    cleared_source?(blob, [])
  end

  def self.require_clean!(blob)
    raise NotCleared, 'Document has not passed its security check' unless cleared?(blob)

    blob
  end

  def owned_by?(owner)
    return false unless owner&.persisted?

    owner.is_a?(User) ? user_id == owner.id : secure_form == owner
  end

  def dismiss!
    with_lock do
      now = Time.current
      attributes = { dismissed_at: dismissed_at || now, lease_token: nil, lease_expires_at: nil, next_attempt_at: nil }
      attributes.merge!(status: :failed, completed_at: now, last_error_code: 'scan_canceled') if pending?
      update!(attributes)
    end
  end

  private

  def upload_owner_present
    owners = [user_id.present?, secure_form_id.present?, continuation == 'docuseal']
    errors.add(:base, 'Upload must have exactly one owner') unless owners.count(true) == 1
  end

  def self.cleared_source?(blob, visited)
    return false if blob.blank? || visited.include?(blob.id)
    return true if exists?(blob_id: blob.id, status: 'clean')

    attachments = blob.attachments.includes(:record).to_a
    return false if attachments.empty?

    attachments.all? { |attachment| cleared_attachment?(attachment, visited + [blob.id]) }
  end

  def self.cleared_attachment?(attachment, visited)
    parent = attachment.record
    if parent.is_a?(PrintQueueItem) && attachment.name == 'pdf_letter'
      true # Letters::Delivery owns this server-generated PDF slot.
    elsif parent.is_a?(ActiveStorage::VariantRecord) && attachment.name == 'image'
      cleared_source?(parent.blob, visited)
    elsif parent.is_a?(ActiveStorage::Blob) && attachment.name == 'preview_image'
      cleared_source?(parent, visited)
    else
      false
    end
  end
  private_class_method :cleared_source?, :cleared_attachment?
end
