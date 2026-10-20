# frozen_string_literal: true

class Product < ApplicationRecord
  has_and_belongs_to_many :evaluations
  has_and_belongs_to_many :vendors,
                          class_name: 'User',
                          join_table: 'products_users'
  has_and_belongs_to_many :applications

  has_many :voucher_transaction_products, dependent: :destroy
  has_many :voucher_transactions, through: :voucher_transaction_products
  has_many :equipment_needs, dependent: :restrict_with_error
  has_many :equipment_items, dependent: :restrict_with_error

  validates :name, presence: true
  validates :manufacturer, presence: true
  validates :model_number, presence: true
  validates :device_types, presence: true
  validates :documentation_url, format: { with: URI::DEFAULT_PARSER.make_regexp }, allow_blank: true
  validate :device_types_must_be_valid

  DEVICE_TYPES = [
    'Smartphone',
    'Tablet',
    'Wearable Device',
    'Captioned Phone',
    'Amplified Phone',
    'Signaler',
    'Speech Device',
    'Smart Home Device',
    'Cellular 911 Alerter',
    'Switch Activated Device',
    'Eye-Tracking System',
    'Hands-free Device',
    'Memory Aid Device',
    'Braille Device'
  ].freeze

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :ordered_by_name, -> { order(:manufacturer, :name) }
  scope :with_selected_types, lambda { |types|
    where('device_types::text[] && ?::text[]', "{#{Array(types).join(',')}}")
  }
  scope :by_device_types, ->(types) { where('device_types && ARRAY[?]::text[]', Array(types)) }
  scope :by_manufacturer, ->(manufacturer) { where(manufacturer: manufacturer) }

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

  def device_types_must_be_valid
    return if device_types.nil?

    invalid_types = device_types - DEVICE_TYPES
    errors.add(:device_types, "contains invalid types: #{invalid_types.join(', ')}") if invalid_types.any?
  end
end
