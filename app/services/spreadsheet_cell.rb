# frozen_string_literal: true

# CSV quoting does not stop spreadsheet software from interpreting a leading formula operator.
# Exports that carry user- or staff-entered text pass each text cell through here, which prefixes
# formula-like text with an apostrophe. Numbers and nil pass through unchanged.
module SpreadsheetCell
  FORMULA_START = /\A\s*[=+\-@]/

  def self.safe(value)
    return value unless value.is_a?(String)
    return value unless value.match?(FORMULA_START)

    "'#{value}"
  end
end
