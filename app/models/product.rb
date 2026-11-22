# frozen_string_literal: true

class Product < ApplicationRecord
  self.filter_attributes += [:documentation_url]

  DEVICE_TYPES = ['Smartphone', 'Tablet', 'Computer', 'Accessory', 'Wearable Device', 'Captioned Phone',
                  'Amplified Phone', 'Signaler', 'Speech Device', 'Smart Home Device', 'Cellular 911 Alerter',
                  'Switch Activated Device', 'Eye-Tracking System', 'Hands-free Device', 'Memory Aid Device', 'Braille Device'].freeze
  CATEGORIES = { 'devices' => 'Devices', 'alerters_accessories_equipment' => 'Alerters, accessories, and equipment' }.freeze
  PROGRAM_GROUPS = { 'deaf' => 'Deaf', 'deafblind' => 'DeafBlind', 'hard_of_hearing' => 'Hard of Hearing',
                     'low_vision_blind' => 'Low Vision / Blind', 'speech' => 'Speech', 'mobility' => 'Mobility' }.freeze
  CATEGORY_DEVICE_TYPES = {
    'devices' => DEVICE_TYPES - %w[Accessory Signaler],
    'alerters_accessories_equipment' => DEVICE_TYPES - %w[Smartphone Tablet Computer]
  }.transform_values(&:freeze).freeze
  UNRESOLVED_IDENTITY = /\A(?:to be (?:selected|confirmed)|unknown|pending)\z/i

  has_and_belongs_to_many :evaluations, join_table: 'evaluations_products'
  has_many :voucher_transaction_products, dependent: :restrict_with_error
  has_many :voucher_transactions, through: :voucher_transaction_products
  has_many :training_sessions, foreign_key: :product_trained_on_id, dependent: :restrict_with_error, inverse_of: :product_trained_on
  has_many :product_resources, dependent: :destroy
  has_many :equipment_needs, dependent: :restrict_with_error
  has_many :equipment_items, dependent: :restrict_with_error
  has_many :bid_group_lines, dependent: :restrict_with_error

  normalizes :manufacturer, :model_number, with: ->(value) { value.to_s.strip.presence }
  before_validation :record_model_identity
  before_destroy :prevent_referenced_destruction, prepend: true

  validates :name, :device_types, :eligible_disability_groups, presence: true
  validates :manufacturer, :model_number, presence: true, if: :model_confirmed?
  validates :category, inclusion: { in: CATEGORIES.keys }
  validates :catalog_key, uniqueness: true, allow_nil: true
  validates :manufacturer_model_identity, uniqueness: { conditions: -> { where(model_confirmed: true) } }, if: :model_confirmed?
  validates :msrp, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal('9999999999.99') }, allow_nil: true
  validates :documentation_url, web_url: true, allow_blank: true
  validate :catalog_classification_is_valid
  validate :confirmed_identity_is_real
  validate :preserve_referenced_identity
  validate :catalog_key_is_immutable

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :model_confirmed, -> { where(model_confirmed: true) }
  scope :available, -> { model_confirmed.active }
  scope :ordered_by_name, -> { order(:manufacturer, :name, :id) }
  scope :by_device_types, ->(types) { where('device_types && ARRAY[?]::text[]', Array(types)) }
  scope :by_manufacturer, ->(manufacturer) { where(manufacturer: manufacturer) }
  scope :eligible_for_groups, ->(groups) { where('eligible_disability_groups && ARRAY[?]::text[]', Array(groups)) }

  def available?
    model_confirmed? && !archived?
  end

  def availability_label
    return 'Draft' unless model_confirmed?

    archived? ? 'Discontinued' : 'Available'
  end

  def catalog_label
    [manufacturer, model_number.presence || name].compact.join(' · ')
  end

  def eligible_for?(groups)
    eligible_disability_groups.intersect?(Array(groups))
  end

  def device_type_choices
    (DEVICE_TYPES | Array(device_types)).sort
  end

  def category_choices
    CATEGORIES.merge((Array(category.presence) - CATEGORIES.keys).index_with { |value| "#{value} (invalid category)" })
  end

  def program_group_choices
    PROGRAM_GROUPS.merge((Array(eligible_disability_groups) - PROGRAM_GROUPS.keys).index_with { |value| "#{value} (invalid group)" })
  end

  def device_type_offered?(type)
    CATEGORY_DEVICE_TYPES.fetch(category, DEVICE_TYPES).include?(type) || Array(device_types).include?(type)
  end

  def referenced?
    evaluations.exists? || training_sessions.exists? || voucher_transaction_products.exists? ||
      equipment_needs.exists? || equipment_items.exists? || bid_group_lines.exists? ||
      Evaluation.exists?(['products_tried @> ?::jsonb', [{ product_id: id.to_s }].to_json])
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def unarchive!
    update!(archived_at: nil)
  end

  def archived?
    archived_at.present?
  end

  private

  def record_model_identity
    self.manufacturer_model_identity = model_confirmed? ? ProductIdentity.key(manufacturer, model_number) : nil
  end

  def catalog_classification_is_valid
    invalid_types = Array(device_types) - CATEGORY_DEVICE_TYPES.fetch(category, DEVICE_TYPES)
    errors.add(:device_types, "are incompatible with this category: #{invalid_types.join(', ')}") if invalid_types.any?
    invalid_groups = Array(eligible_disability_groups) - PROGRAM_GROUPS.keys
    errors.add(:eligible_disability_groups, 'contains an unknown program group') if invalid_groups.any?
  end

  def confirmed_identity_is_real
    return unless model_confirmed?
    return unless [manufacturer, model_number].any? { |value| value.to_s.match?(UNRESOLVED_IDENTITY) }

    errors.add(:model_confirmed, 'requires an exact manufacturer and model')
  end

  def preserve_referenced_identity
    return unless persisted? && model_confirmed_in_database
    return unless will_save_change_to_manufacturer_model_identity? || !model_confirmed?
    return unless referenced?

    errors.add(:base, 'A referenced exact model cannot be changed or reverted to draft. Create another product or discontinue this model.')
  end

  def catalog_key_is_immutable
    return unless persisted? && catalog_key_in_database.present? && will_save_change_to_catalog_key?

    errors.add(:catalog_key, 'cannot be changed')
  end

  def prevent_referenced_destruction
    return unless referenced?

    errors.add(:base, 'Referenced products must be discontinued instead of deleted.')
    throw(:abort)
  end
end
