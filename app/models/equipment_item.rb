# frozen_string_literal: true

class EquipmentItem < ApplicationRecord
  include TypedDateInput
  include EquipmentShipping
  include Icanconnect::FundedEquipment

  DISPATCH_READY_SQL = <<~SQL.squish.freeze
    (equipment_items.fulfillment_source = 'direct_vendor' AND purchase_orders.sent_at IS NOT NULL)
    OR (equipment_items.fulfillment_source != 'direct_vendor' AND equipment_items.stock_received_on IS NOT NULL)
  SQL

  CARRIERS = { 'ups' => 'UPS', 'fedex' => 'FedEx', 'usps' => 'USPS', 'dhl' => 'DHL', 'other' => 'Other / Not recorded' }.freeze

  belongs_to :application, optional: true
  belongs_to :acquisition_bid_group_line, class_name: 'BidGroupLine', optional: true
  belongs_to :allocation_equipment_need, class_name: 'EquipmentNeed', optional: true
  belongs_to :replaced_by_equipment_item, class_name: 'EquipmentItem', optional: true
  has_many :bid_group_lines, dependent: :restrict_with_error
  enum :fulfillment_source, { direct_vendor: 'direct_vendor', program_stock_po: 'program_stock_po', existing_stock: 'existing_stock' }, validate: true
  belongs_to :product
  belongs_to :purchase_order, optional: true
  belongs_to :source_evaluation, class_name: 'Evaluation', optional: true
  has_many :events, as: :auditable, dependent: :restrict_with_error

  encrypts :tracking_number, :serial_number, :imei
  encrypts :normalized_imei, :normalized_serial_number, deterministic: true
  typed_date_input :shipped_at
  typed_date_input :stock_received_on
  attr_accessor :allocation_mutation

  attr_reader :identity_conflicts

  normalizes :tracking_number, :serial_number, :imei, :carrier, with: ->(value) { value.to_s.strip.presence }
  before_validation :record_identity

  validates :carrier, inclusion: { in: CARRIERS.keys }, allow_nil: true
  validates :tracking_number, :serial_number, length: { maximum: 128 }, allow_nil: true
  validates :normalized_imei, format: { with: /\A\d{15}\z/, message: 'must contain 15 digits' }, allow_nil: true
  validates :manufacturer_model_identity, :normalized_manufacturer, presence: true
  validates :disability_setup_group, inclusion: { in: ->(_) { Product::PROGRAM_GROUPS.keys } }, allow_nil: true
  validate :beneficiary_is_consistent
  validate :acquisition_is_consistent
  validate :withdrawal_is_consistent
  validate :receipt_is_consistent
  validate :shipment_is_consistent
  validate :active_identifiers_are_unique

  scope :active, -> { where(withdrawn_at: nil) }
  scope :needs_ordering, -> { active.direct_vendor.where(purchase_order_id: nil, shipped_at: nil) }
  scope :ordered, lambda {
    active.left_joins(:purchase_order).where(shipped_at: nil).where.not(application_id: nil).where(DISPATCH_READY_SQL)
  }
  scope :portal_visible, lambda {
    active.where.not(application_id: nil).left_joins(:purchase_order)
          .where("equipment_items.shipped_at IS NOT NULL OR (#{DISPATCH_READY_SQL})")
  }
  scope :shipped, -> { active.where.not(shipped_at: nil) }
  scope :stock, -> { where.not(fulfillment_source: 'direct_vendor') }
  scope :available_stock, -> { active.stock.where(application_id: nil, shipped_at: nil).where.not(stock_received_on: nil) }
  scope :incoming_stock, -> { active.program_stock_po.joins(:purchase_order).where(stock_received_on: nil).where.not(purchase_orders: { sent_at: nil }) }
  scope :reserved_stock, -> { active.stock.where(shipped_at: nil).where.not(application_id: nil).where.not(stock_received_on: nil) }

  def self.normalize_identity(value)
    ProductIdentity.normalize(value)
  end

  def self.normalized_identity(manufacturer, model_number)
    ProductIdentity.key(manufacturer, model_number)
  end

  # Batch writers take their row locks before locking all new identifier keys.
  def self.lock_identity_assignments!(items)
    items.each { |item| item.send(:record_identity) }
    keys = items.reject(&:withdrawn_at?).flat_map { |item| item.send(:identity_lock_keys) }.uniq.sort
    keys.each do |key|
      bind = ActiveRecord::Relation::QueryAttribute.new('key', key, ActiveRecord::Type::BigInteger.new)
      connection.exec_query('SELECT pg_advisory_xact_lock($1)::text', 'Equipment identity assignment lock', [bind])
    end
  end

  def stock?
    !direct_vendor?
  end

  def stock_receipt_batch
    "#{acquisition_bid_group_line_id}-#{product_id}"
  end

  def equipment_history
    Event.where(auditable: self).or(Event.with_metadata(:equipment_item_ids, [id])).includes(:user).order(created_at: :desc, id: :desc)
  end

  def awaiting_shipment?
    !withdrawn_at? && application_id? && !shipped_at? && (direct_vendor? ? purchase_order&.sent_at.present? : stock_received_on.present?)
  end

  def shipment_wait_started_at
    stock? ? stock_allocated_at : purchase_order&.sent_at
  end

  def setup_ready?
    return false unless Product::PROGRAM_GROUPS.key?(disability_setup_group)
    return true unless queue_status == 'needs_ordering'

    application.program_disability_groups.include?(disability_setup_group)
  end

  def portal_visible?
    (!withdrawn_at? && application_id? && shipped_at?) || awaiting_shipment?
  end

  def available_quantity
    return 0 unless queue_status == 'needs_ordering'

    reserved = bid_group_lines.loaded? ? bid_group_lines.any?(&:reserved?) : bid_group_lines.reserved.exists?
    reserved ? 0 : 1
  end

  def queue_status
    return 'withdrawn' if withdrawn_at?
    return 'shipped' if shipped_at?
    return 'available_stock' if stock? && !application_id? && stock_received_on?
    return 'incoming_stock' if stock? && !stock_received_on?
    return 'awaiting_shipment' if awaiting_shipment?
    return 'ready_to_send_po' if purchase_order_id?

    'needs_ordering'
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

  def beneficiary_is_consistent
    if persisted? && will_save_change_to_application_id? && (!allocation_mutation || direct_vendor? || shipped_at_in_database)
      errors.add(:application, 'must be changed through stock allocation before shipment')
    end
    errors.add(:application, 'is required for direct equipment') if direct_vendor? && !application
    return unless source_evaluation && source_evaluation.application_id != application_id

    errors.add(:source_evaluation, 'must belong to this application')
  end

  def acquisition_is_consistent
    errors.add(:base, 'Physical acquisition provenance cannot change') if persisted? && acquisition_provenance_changed?
    errors.add(:purchase_order, 'has the wrong purpose') if purchase_order && purchase_order.program_stock? != program_stock_po?
    errors.add(:acquisition_bid_group_line, 'must identify this stock acquisition') if program_stock_po? && !stock_acquisition_matches?
    return unless existing_stock? && (intake_provenance.blank? || stock_received_on.blank?)

    errors.add(:intake_provenance, 'and the verified on-hand date are required')
  end

  def acquisition_provenance_changed?
    will_save_change_to_fulfillment_source? || will_save_change_to_acquisition_bid_group_line_id? ||
      (stock? && will_save_change_to_purchase_order_id?)
  end

  def stock_acquisition_matches?
    return false unless acquisition_bid_group_line && acquisition_bid_group_line.bid_group.purchase_order_id == purchase_order_id

    !(new_record? || will_save_change_to_acquisition_bid_group_line_id?) || acquisition_bid_group_line.product_id == product_id
  end

  def withdrawal_is_consistent
    errors.add(:purchase_order, 'must be cleared before withdrawal') if direct_vendor? && withdrawn_at? && purchase_order_id?
    errors.add(:base, 'Release the stock allocation before removing this unit') if stock? && withdrawn_at? && application_id?
  end

  def receipt_is_consistent
    errors.add(:stock_received_on, 'applies only to program stock') if direct_vendor? && stock_received_on
    receipt_date_is_consistent if stock_received_on
    return unless persisted? && stock? && will_save_change_to_stock_received_on? && (application_id? || shipped_at?)

    errors.add(:stock_received_on, 'requires resolving allocation and shipment first')
  end

  def receipt_date_is_consistent
    errors.add(:stock_received_on, 'cannot be in the future') if stock_received_on.future?
    return unless program_stock_po? && (!purchase_order&.sent_at || stock_received_on < purchase_order.sent_at)

    errors.add(:stock_received_on, 'requires a sent PO and cannot precede its sent date')
  end

  def shipment_is_consistent
    return if shipped_at.blank?

    errors.add(:shipped_at, 'cannot be in the future') if shipped_at > Date.current
    direct_vendor? ? direct_shipment_is_consistent : stock_dispatch_is_consistent
    errors.add(:tracking_number, 'is required when recording shipment') if tracking_number.blank?
    errors.add(:base, 'Confirm destination and setup before shipment') unless shipping_ready? && disability_setup_group.present?
    errors.add(:withdrawn_at, 'cannot withdraw shipped equipment') if withdrawn_at?
  end

  def direct_shipment_is_consistent
    errors.add(:purchase_order, 'must be sent before shipment') unless purchase_order&.sent_at
    return unless purchase_order&.sent_at && shipped_at < purchase_order.sent_at

    errors.add(:shipped_at, 'cannot precede the PO sent date')
  end

  def stock_dispatch_is_consistent
    errors.add(:application, 'is required before dispatch') unless application_id?
    errors.add(:shipped_at, 'requires received stock and cannot precede receipt') unless stock_received_on && shipped_at >= stock_received_on
    errors.add(:setup_confirmed_at, 'confirm the constituent setup before dispatch') unless setup_confirmed_at
  end

  def active_identifiers_are_unique
    @identity_conflicts = []
    return if withdrawn_at?

    lock_identity_assignment if identity_assignment_changed? && (normalized_serial_number.present? || normalized_imei.present?)
    others = self.class.active.where.not(id: id)
    if normalized_imei.present?
      duplicate = others.find_by(normalized_imei: normalized_imei)
      add_identity_conflict(:imei, duplicate) if duplicate
    end
    return if normalized_serial_number.blank?

    duplicate = others.find_by(manufacturer_model_identity: manufacturer_model_identity, normalized_serial_number: normalized_serial_number)
    add_identity_conflict(:serial_number, duplicate) if duplicate
  end

  def lock_identity_assignment
    connection = self.class.connection
    return unless connection.transaction_open? # Standalone validation is a read-only preview.

    # Take rows before the serial lock, including foreign keys that a direct save will check.
    if new_record? || will_save_change_to_purchase_order_id?
      Application.where(id: application_id).lock.pick(:id)
      PurchaseOrder.where(id: [purchase_order_id_in_database, purchase_order_id].compact).order(:id).lock.pluck(:id)
    end
    self.class.where(id: id).lock.pick(:id) if persisted?
    self.class.lock_identity_assignments!([self])
  end

  def identity_lock_keys
    identities = []
    identities << ['equipment-serial', normalized_manufacturer, normalized_serial_number] if normalized_serial_number.present?
    identities << ['equipment-imei', normalized_imei] if normalized_imei.present?
    identities.map { |identity| Digest::SHA256.digest(identity.to_json).unpack1('q>') }
  end

  def identity_assignment_changed?
    new_record? || will_save_change_to_product_id? || will_save_change_to_normalized_serial_number? ||
      will_save_change_to_normalized_imei? || will_save_change_to_withdrawn_at?
  end

  def add_identity_conflict(attribute, duplicate)
    errors.add(attribute, "is already assigned to active equipment item ##{duplicate.id}")
    @identity_conflicts << duplicate
  end
end
