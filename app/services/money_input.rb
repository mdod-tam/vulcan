# frozen_string_literal: true

# The one reading of a typed dollar amount. Accepts an optional leading "$", digits with commas only
# in valid thousands groups, and at most two decimal places. Returns a BigDecimal, or nil for anything
# else, including fractional cents ("10.005") and misplaced commas ("1,2"). Never goes through Float.
class MoneyInput
  FORMAT = /\A\$?(?<digits>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<cents>\d{1,2}))?\z/

  def self.parse(value)
    return value if value.is_a?(BigDecimal)

    match = value.to_s.strip.match(FORMAT)
    return nil unless match

    BigDecimal("#{match[:digits].delete(',')}.#{match[:cents] || '0'}")
  end
end
