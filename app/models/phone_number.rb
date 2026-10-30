# frozen_string_literal: true

# US phone numbers as the app stores, compares and validates them: ten digits written ddd-ddd-dddd, with a
# leading country code 1 dropped. A dependent with no phone of their own carries a synthetic number that
# starts with 000; it keeps the record valid but reaches no one.
module PhoneNumber
  SYNTHETIC_PREFIX = '000'

  module_function

  # @return [String, nil] The ten national digits, or nil when the value is not a US phone number
  def national_digits(value)
    digits = value.to_s.gsub(/\D/, '')
    digits = digits[1..] if digits.length == 11 && digits.start_with?('1')
    digits if digits.length == 10
  end

  # The stored form. A value that is not a US number comes back unchanged, so validation can refuse it.
  # @return [String, nil] ddd-ddd-dddd, the value as given, or nil for a blank value
  def normalize(value)
    return nil if value.blank?

    digits = national_digits(value)
    digits ? digits.gsub(/(\d{3})(\d{3})(\d{4})/, '\1-\2-\3') : value.to_s
  end

  def valid?(value)
    national_digits(value).present?
  end

  def synthetic?(value)
    normalize(value).to_s.gsub(/\D/, '').start_with?(SYNTHETIC_PREFIX)
  end

  # A valid number a person could answer, as opposed to a blank or synthetic one.
  def real?(value)
    value.present? && !synthetic?(value) && valid?(value)
  end
end
