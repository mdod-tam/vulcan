# frozen_string_literal: true

module EquipmentShipping
  extend ActiveSupport::Concern

  FIELDS = %w[shipping_care_of shipping_address_1 shipping_address_2 shipping_city shipping_state shipping_zip_code].freeze
  REQUIRED_FIELDS = %w[shipping_address_1 shipping_city shipping_state shipping_zip_code].freeze

  included do
    encrypts(*FIELDS)
    normalizes(*FIELDS, with: ->(value) { value.to_s.strip.presence })
    validates(*FIELDS, length: { maximum: 255 }, allow_nil: true)
  end

  def shipping_snapshot
    attributes.slice(*FIELDS)
  end

  def shipping_ready?
    REQUIRED_FIELDS.all? { |field| public_send(field).present? }
  end

  def shipping_label
    [shipping_care_of.presence&.then { |name| "c/o #{name}" }, shipping_address_1, shipping_address_2,
     [shipping_city, shipping_state, shipping_zip_code].compact_blank.join(', ')].compact_blank.join("\n")
  end
end
