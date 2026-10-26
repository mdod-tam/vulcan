# frozen_string_literal: true

# Builds ApplicationDataStructures::Address objects from a user or from parameters, and validates them.
module AddressHelper
  extend ActiveSupport::Concern

  private

  # Creates an Address object from user data
  # @param user [User] The user to extract address from
  # @return [ApplicationDataStructures::Address] Address object
  def address_from_user(user)
    ApplicationDataStructures::Address.new(
      physical_address_1: user.physical_address_1,
      physical_address_2: user.physical_address_2,
      city: user.city,
      state: user.state,
      zip_code: user.zip_code
    )
  end

  # Creates an Address object from application parameters
  # @param params_hash [Hash] Parameters containing address fields
  # @return [ApplicationDataStructures::Address] Address object
  def address_from_params(params_hash)
    ApplicationDataStructures::Address.new(
      physical_address_1: params_hash[:physical_address_1] || params_hash[:physical_address1],
      physical_address_2: params_hash[:physical_address_2] || params_hash[:physical_address2],
      city: params_hash[:city],
      state: params_hash[:state],
      zip_code: params_hash[:zip_code]
    )
  end

  # Creates an Address object with fallback logic (params first, then user)
  # @param params_hash [Hash] Parameters containing address fields
  # @param user [User] User to fallback to for missing fields
  # @return [ApplicationDataStructures::Address] Address object
  def address_with_fallback(params_hash, user)
    ApplicationDataStructures::Address.new(
      physical_address_1: params_hash[:physical_address_1] || params_hash[:physical_address1] || user.physical_address_1,
      physical_address_2: params_hash[:physical_address_2] || params_hash[:physical_address2] || user.physical_address_2,
      city: params_hash[:city] || user.city,
      state: params_hash[:state] || user.state,
      zip_code: params_hash[:zip_code] || user.zip_code
    )
  end

  # Validates an address and returns error messages
  # @param address [ApplicationDataStructures::Address] Address to validate
  # @return [Array<String>] Array of error messages (empty if valid)
  def validate_address(address)
    errors = []
    errors << 'Street address is required' if address.physical_address_1.blank?
    errors << 'City is required' if address.city.blank?
    errors << 'State is required' if address.state.blank?
    errors << 'ZIP code is required' if address.zip_code.blank?
    errors
  end
end
