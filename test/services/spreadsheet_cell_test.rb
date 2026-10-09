# frozen_string_literal: true

require 'test_helper'

class SpreadsheetCellTest < ActiveSupport::TestCase
  test 'formula-like text is prefixed and everything else passes through' do
    assert_equal "'=HYPERLINK(\"x\")", SpreadsheetCell.safe('=HYPERLINK("x")')
    assert_equal "' +1", SpreadsheetCell.safe(' +1')
    assert_equal "'-2", SpreadsheetCell.safe('-2')
    assert_equal "'@SUM(A1)", SpreadsheetCell.safe('@SUM(A1)')
    assert_equal 'Ray Supply', SpreadsheetCell.safe('Ray Supply')
    assert_equal BigDecimal('-5'), SpreadsheetCell.safe(BigDecimal('-5'))
    assert_nil SpreadsheetCell.safe(nil)
  end
end
