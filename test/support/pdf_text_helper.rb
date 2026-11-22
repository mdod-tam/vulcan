# frozen_string_literal: true

require 'pdf/reader'
require 'stringio'

module PdfTextHelper
  private

  def extracted_pdf_text(pdf_binary)
    PDF::Reader.new(StringIO.new(pdf_binary)).pages.map(&:text).join("\n")
  end
end
