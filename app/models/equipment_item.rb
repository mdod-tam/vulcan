# frozen_string_literal: true

class EquipmentItem < ApplicationRecord
  include TypedDateInput

  CARRIERS = { 'ups' => 'UPS', 'fedex' => 'FedEx', 'usps' => 'USPS', 'other' => 'Other / Not recorded' }.freeze

  belongs_to :application
  belongs_to :product
  belongs_to :purchase_order, optional: true
  belongs_to :source_evaluation, class_name: 'Evaluation', optional: true
  has_many :events, as: :auditable, dependent: :restrict_with_error

  encrypts :tracking_number, :serial_number, :imei
  encrypts :normalized_imei, :normalized_serial_number, deterministic: true
  typed_date_input :shipped_at

  attr_accessor :serial_duplicate_reason
  attr_reader :identity_conflicts

  normalizes :tracking_number, :serial_number, :imei, :carrier, with: ->(value) { value.to_s.strip.presence }
  before_validation :record_identity

  validates :carrier, inclusion: { in: CARRIERS.keys }, allow_nil: true
  validates :tracking_number, :serial_number, length: { maximum: 128 }, allow_nil: true
  validates :normalized_imei, format: { with: /\A\d{15}\z/, message: 'must contain 15 digits' }, allow_nil: true
  validates :manufacturer_model_identity, :normalized_manufacturer, presence: true
  validate :relationships_are_consistent
  validate :shipment_is_consistent
  validate :active_identifiers_are_unique

  scope :active, -> { where(withdrawn_at: nil) }
  scope :needs_ordering, -> { active.where(purchase_order_id: nil, shipped_at: nil) }
  scope :ordered, -> { active.where.not(purchase_order_id: nil).where(shipped_at: nil) }
  scope :shipped, -> { active.where.not(purchase_order_id: nil).where.not(shipped_at: nil) }

  def self.normalize_identity(value)
    value.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
  end

  def self.normalized_identity(manufacturer, model_number)
    Digest::SHA256.hexdigest([normalize_identity(manufacturer), normalize_identity(model_number)].to_json)
  end

  def queue_status
    return 'withdrawn' if withdrawn_at?
    return 'needs_ordering' unless purchase_order_id?

    shipped_at? ? 'shipped' : 'ordered'
  end

  def potential_serial_duplicates
    return self.class.none if normalized_serial_number.blank? || withdrawn_at?

    self.class.active.where(normalized_manufacturer: normalized_manufacturer,
                            normalized_serial_number: normalized_serial_number)
        .where.not(id: id).where.not(manufacturer_model_identity: manufacturer_model_identity)
  end

  private

  def record_identity
    if product && (new_record? || will_save_change_to_product_id?)
      self.normalized_manufacturer = self.class.normalize_identity(product.manufacturer)
      self.manufacturer_model_identity = self.class.normalized_identity(product.manufacturer, product.model_number)
    end
    self.normalized_imei = imei&.gsub(/[\s-]/, '')&.presence
    self.normalized_serial_number = serial_number.to_s.unicode_normalize(:nfkc).upcase.gsub(/\s+/, '').presence
  end

  def relationships_are_consistent
    errors.add(:application, 'cannot be changed for an existing device') if persisted? && will_save_change_to_application_id?
    errors.add(:source_evaluation, 'must belong to this application') if source_evaluation && source_evaluation.application_id != application_id
    errors.add(:purchase_order, 'must be cleared before withdrawal') if withdrawn_at? && purchase_order_id?
  end

  def shipment_is_consistent
    return if shipped_at.blank?

    errors.add(:shipped_at, 'cannot be in the future') if shipped_at > Date.current
    errors.add(:purchase_order, 'is required before shipment') unless purchase_order
    errors.add(:shipped_at, 'cannot precede the purchase order date') if purchase_order&.sent_at && shipped_at < purchase_order.sent_at
    errors.add(:tracking_number, 'is required when recording shipment') if tracking_number.blank?
    errors.add(:withdrawn_at, 'cannot withdraw shipped equipment') if withdrawn_at?
  end

  def active_identifiers_are_unique
    @identity_conflicts = []
    return if withdrawn_at?

    lock_serial_assignment if identity_assignment_changed? && normalized_serial_number.present?
    others = self.class.active.where.not(id: id)
    if normalized_imei.present?
      duplicate = others.find_by(normalized_imei: normalized_imei)
      add_identity_conflict(:imei, duplicate) if duplicate
    end
    return if normalized_serial_number.blank?

    duplicate = others.find_by(manufacturer_model_identity: manufacturer_model_identity, normalized_serial_number: normalized_serial_number)
    add_identity_conflict(:serial_number, duplicate) if duplicate
    return unless identity_assignment_changed? && potential_serial_duplicates.exists? && serial_duplicate_reason.blank?

    errors.add(:serial_number, 'matches another model from this manufacturer; provide an acknowledgment reason after reviewing the potential duplicate')
    @identity_conflicts.concat(potential_serial_duplicates.to_a)
  end

  def lock_serial_assignment
    connection = self.class.connection
    return unless connection.transaction_open? # Standalone validation is a read-only preview.

    # Take rows before the serial lock, including foreign keys that a direct save will check.
    if new_record? || will_save_change_to_purchase_order_id?
      Application.where(id: application_id).lock.pick(:id)
      PurchaseOrder.where(id: [purchase_order_id_in_database, purchase_order_id].compact).order(:id).lock.pluck(:id)
    end
    self.class.where(id: id).lock.pick(:id) if persisted?
    key = Digest::SHA256.digest(['equipment-serial', normalized_manufacturer, normalized_serial_number].to_json).unpack1('q>')
    bind = ActiveRecord::Relation::QueryAttribute.new('key', key, ActiveRecord::Type::BigInteger.new)
    connection.exec_query('SELECT pg_advisory_xact_lock($1)::text', 'Equipment serial assignment lock', [bind])
  end

  def identity_assignment_changed?
    new_record? || will_save_change_to_product_id? || will_save_change_to_normalized_serial_number? || will_save_change_to_withdrawn_at?
  end

  def add_identity_conflict(attribute, duplicate)
    errors.add(attribute, "is already assigned to active equipment item ##{duplicate.id}")
    @identity_conflicts << duplicate
  end
end
