# frozen_string_literal: true

# DB-stored, admin-editable rejection reasons for proof reviews.
# Each record is uniquely identified by (code, proof_type, locale).
# Proof type is stored as a plain string ("income", "residency", or
# "disability_certification") so disability cert rejections can share the model.
class RejectionReason < ApplicationRecord
  belongs_to :updated_by, class_name: 'User', optional: true

  # Display names staff see for reason codes in every rejection form. Codes not listed read as titles.
  LABELS = {
    'missing_amount' => 'Missing Income Amount',
    'exceeds_threshold' => 'Income Exceeds Threshold',
    'outdated_ss_award' => 'Outdated Social Security Award Letter',
    'missing_signature' => 'Missing Signature',
    'wrong_document' => 'Wrong Document Type',
    'address_mismatch' => 'Address Mismatch',
    'missing_name' => 'Missing Name',
    'missing_provider_credentials' => 'Missing Provider Credentials',
    'incomplete_disability_documentation' => 'Incomplete Disability Documentation',
    'outdated_certification' => 'Outdated Certification',
    'missing_functional_limitations' => 'Missing Functional Limitations',
    'incorrect_form_used' => 'Incorrect Form Used',
    'incomplete_documentation' => 'Incomplete Documentation',
    'illegible' => 'Illegible or Unclear'
  }.freeze

  def self.label_for(code)
    LABELS.fetch(code.to_s) { code.to_s.humanize.titleize }
  end

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

  VALID_PROOF_TYPES = %w[income residency id disability_certification].freeze

  # Returns the best-matching record for (code, proof_type, locale), falling
  # back to English when no locale-specific record exists.
  def self.resolve(code:, proof_type:, locale: 'en')
    find_by(code: code, proof_type: proof_type, locale: locale) ||
      find_by(code: code, proof_type: proof_type, locale: 'en')
  end

  # The codes the rejection forms offer themselves, apart from the reasons stored here.
  FORM_OWN_CODES = %w[none_provided other].freeze

  # The reasons a rejection form offers: one per proof type and code, in the locale where it has one and
  # in English otherwise. proof_type: nil offers every proof type.
  def self.options_for(locale: 'en', proof_type: nil)
    scope = where(locale: [locale.to_s, 'en']).where.not(code: FORM_OWN_CODES)
    scope = scope.where(proof_type: proof_type) if proof_type
    scope.order(:proof_type, :code).group_by { |reason| [reason.proof_type, reason.code] }.values.map do |variants|
      variants.find { |reason| reason.locale == locale.to_s } || variants.first
    end
  end

  # What a reason body may state about the application. Every place that fills a body uses this.
  def self.interpolations_for(application)
    { address: application&.user&.mailing_address_line.to_s }
  end

  # Returns { text:, code: } for persisting to ProofReview. The application supplies the address that
  # reasons such as address_mismatch state.
  def self.resolve_for_persistence(code:, proof_type:, fallback:, application: nil, locale: 'en')
    return { text: fallback.to_s.presence, code: nil } if code.blank?

    rr = resolve(code: code, proof_type: proof_type, locale: locale)
    resolved_text = interpolate_body(rr&.body || fallback, application ? interpolations_for(application) : {})
    {
      text: resolved_text,
      code: rr ? code : nil
    }
  end

  # Returns the human-readable body for the given code and proof type,
  # or the fallback when code is blank or no record exists.
  def self.resolve_text(code:, proof_type:, fallback:, application: nil, locale: 'en')
    resolve_for_persistence(
      code: code, proof_type: proof_type, fallback: fallback, application: application, locale: locale
    )[:text]
  end

  def self.interpolate_body(body, interpolations = {})
    return body if interpolations.blank?
    return body unless body.to_s.include?('%{') || body.to_s.include?('%<')

    body % interpolations.transform_keys(&:to_sym)
  rescue KeyError, ArgumentError
    body
  end

  # This reason's body with the application's details filled in.
  def body_for(application)
    self.class.interpolate_body(body, self.class.interpolations_for(application))
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
