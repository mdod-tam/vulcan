# frozen_string_literal: true

# CSV quoting does not stop spreadsheet software from interpreting a leading formula operator.
# CsvExport applies this policy to headers and cells. Numbers and nil pass through unchanged.
# This protects the initial export; spreadsheet save/reopen behavior can remove escaping.
module SpreadsheetCell
  FORMULA_START = /\A[\p{Space}\p{Cc}\p{Cf}]*[=+\-@＝＋－＠\t\r\n]/

  def self.safe(value)
    return value unless value.is_a?(String)
    return value unless value.match?(FORMULA_START)

    "'#{value}"
  end
end
