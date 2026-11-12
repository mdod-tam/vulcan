# frozen_string_literal: true

require 'zlib'

module PdfTextHelper
  private

  # Prawn uses FlateDecode and hex glyph runs with kerning splits ("[<4c4554...> 90 <59...>] TJ").
  # This extracts text without a PDF parser.
  def inflated_pdf_text(pdf_binary)
    content = pdf_binary.scan(/stream\r?\n(.*?)endstream/m).flatten.map do |stream|
      Zlib::Inflate.inflate(stream)
    rescue Zlib::Error
      stream.dup
    end.join
    content.scan(/<([0-9a-fA-F]+)>/).flatten.map { |hex| [hex].pack('H*') }.join.force_encoding('BINARY')
  end
end
