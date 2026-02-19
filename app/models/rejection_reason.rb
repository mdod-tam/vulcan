# frozen_string_literal: true

# DB-stored, admin-editable rejection reasons for proof reviews.
# Each record is uniquely identified by (code, proof_type, locale).
# Proof type is stored as a plain string ("income", "residency", or
# "medical_certification") so medical cert rejections can share the model.
class RejectionReason < ApplicationRecord
  belongs_to :updated_by, class_name: 'User', optional: true

  validates :code,       presence: true
  validates :proof_type, presence: true
  validates :locale,     presence: true
  validates :body,       presence: true
  validates :version,    presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :code, uniqueness: { scope: %i[proof_type locale] }

  before_update :store_previous_body
  before_update :increment_version

  # Flag sibling locales when this record's body changes (mirrors EmailTemplate pattern).
  # Guard: skipped when needs_sync is already true (that save is resolving the sync).
  after_update :flag_counterpart_locales_for_sync,
               if: -> { saved_change_to_body? && !needs_sync? }

  # Clear our own flag after a content update that resolved the out-of-sync state.
  after_update :clear_sync_flag,
               if: -> { saved_change_to_body? && needs_sync? }

  # Block non-content saves while out of sync; a body change always resolves it.
  validate :counterpart_locales_are_synced, on: :update

  VALID_PROOF_TYPES = %w[income residency medical_certification].freeze

  # Returns the best-matching record for (code, proof_type, locale), falling
  # back to English when no locale-specific record exists.
  def self.resolve(code:, proof_type:, locale: 'en')
    find_by(code: code, proof_type: proof_type, locale: locale) ||
      find_by(code: code, proof_type: proof_type, locale: 'en')
  end

  # Returns { text:, code: } for persisting to ProofReview
  def self.resolve_for_persistence(code:, proof_type:, fallback:, locale: 'en')
    return { text: fallback.to_s.presence, code: nil } if code.blank?

    rr = resolve(code: code, proof_type: proof_type, locale: locale)
    {
      text: rr&.body || fallback,
      code: rr ? code : nil
    }
  end

  # Returns the human-readable body for the given code and proof type,
  # or the fallback when code is blank or no record exists.
  def self.resolve_text(code:, proof_type:, fallback:, locale: 'en')
    resolve_for_persistence(
      code: code, proof_type: proof_type, fallback: fallback, locale: locale
    )[:text]
  end

  private

  def store_previous_body
    self.previous_body = body_was if body_changed?
  end

  def increment_version
    self.version += 1 if body_changed?
  end

  def flag_counterpart_locales_for_sync
    RejectionReason.where(code: code, proof_type: proof_type)
                   .where.not(locale: locale)
                   .update_all(needs_sync: true) # rubocop:disable Rails/SkipsModelValidations
  end

  def clear_sync_flag
    update_column(:needs_sync, false) # rubocop:disable Rails/SkipsModelValidations
  end

  def counterpart_locales_are_synced
    return unless needs_sync?
    return if body_changed?

    errors.add(:base, 'This reason is out of sync with another locale variant. ' \
                      'Update the body to resolve it, or mark it synced.')
  end
end
