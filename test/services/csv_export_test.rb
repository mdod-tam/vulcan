# frozen_string_literal: true

require 'bundler/setup'
require 'minitest/autorun'
require 'active_support/test_case'
require 'bigdecimal'
require 'tempfile'
require_relative '../../app/services/csv_export'

class CsvExportTest < ActiveSupport::TestCase
  test 'headers and text cells receive the same formula policy including controls and fullwidth operators' do
    starts = ['=', '+', '-', '@', '＝', '＋', '－', '＠', "\t", "\r", "\n", " \u0000=", "\uFEFF＋", "\u00A0@"]
    output = +''
    writer = CsvExport.new(output, headers: starts)
    writer << starts.map { |start| "#{start}SUM(1,2)" }

    # These custom headers contain CR before the first record; avoid automatic separator guessing.
    rows = CSV.parse(output, row_sep: "\n")
    assert_equal starts.map { |start| "'#{start}" }, rows.first
    assert_equal starts.map { |start| "'#{start}SUM(1,2)" }, rows.last
    assert_equal 1, writer.row_count
  end

  test 'numbers stay numeric text while negative numeric strings are neutralized' do
    output = +''
    writer = CsvExport.new(output, headers: %w[integer decimal numeric_text empty ordinary])
    writer << [-7, BigDecimal('-12.50'), '-12.50', nil, '  ordinary text']

    row = CSV.parse(output, headers: true).sole
    assert_equal '-7', row['integer']
    assert_equal BigDecimal('-12.50'), BigDecimal(row['decimal'])
    assert_not row['decimal'].start_with?("'")
    assert_equal "'-12.50", row['numeric_text']
    assert_nil row['empty']
    assert_equal '  ordinary text', row['ordinary']
  end

  test 'quotes separators and embedded newlines remain inside their original cells' do
    output = +''
    writer = CsvExport.new(output, headers: %w[name details])
    writer << ['Doe, "Jane"', "ordinary\n=SUM(1,2);\"@value\""]
    writer << ['=HYPERLINK("https://example.invalid","label")', 'second row']

    rows = CSV.parse(output, headers: true)
    assert_equal 2, rows.size
    assert_equal ['Doe, "Jane"', "ordinary\n=SUM(1,2);\"@value\""], rows.first.fields
    assert_equal "'=HYPERLINK(\"https://example.invalid\",\"label\")", rows[1]['name']
    assert_equal 2, writer.row_count
  end

  test 'IO output streams the same policy without taking ownership of the caller file' do
    Tempfile.create(['csv-export', '.csv']) do |file|
      writer = CsvExport.new(file, headers: %w[Name Quantity])
      writer << ['＠unsafe', 2]
      file.flush
      file.rewind

      assert_equal [['Name', 'Quantity'], ["'＠unsafe", '2']], CSV.parse(file.read)
      assert_not file.closed?
      assert_equal 1, writer.row_count
    end
  end
end
