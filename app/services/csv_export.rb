# frozen_string_literal: true

require 'csv'
require_relative 'spreadsheet_cell'

# The serialization boundary for exported text, including headers. Callers supply typed cells.
class CsvExport
  attr_reader :row_count

  def self.generate(headers:, actor:, export_type:)
    output = +''
    writer = new(output, headers: headers)
    yield writer
    AuditEventService.log(action: 'export_generated', actor: actor,
                          metadata: { export_type: export_type, row_count: writer.row_count })
    output
  end

  def initialize(output, headers:)
    @csv = CSV.new(output, row_sep: "\n")
    @row_count = 0
    @csv << headers.map { |value| SpreadsheetCell.safe(value) } unless headers.empty?
  end

  def <<(row)
    @csv << row.map { |value| SpreadsheetCell.safe(value) }
    @row_count += 1
    self
  end
end
