# frozen_string_literal: true

module Letters
  class PdfDocument < Prawn::Document
    LATIN_FONT = 'Noto Sans'
    CJK_FONT = 'Noto Sans CJK'
    FONT_ROOT = Rails.root.join('vendor/fonts')
    # Prawn lays out individual glyphs. Accept scripts that work without shaping,
    # and compose canonically equivalent accents before checking glyph coverage.
    SUPPORTED_CHARACTER = /\A[\p{Latin}\p{Cyrillic}\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Common}]\z/
    LAYOUT_CHARACTER = /\A[\r\n\t]\z/
    NON_PRINTING = /[\p{C}\p{M}]/
    PASTE_CHARACTERS = "\u00AD\u200B\u200E"

    def initialize
      super(&nil)
      font_families.update(
        LATIN_FONT => font_files('NotoSans'),
        CJK_FONT => font_files('NotoSansCJKjp')
      )
      font(LATIN_FONT)
      yield self if block_given?
    end

    def text(string, options = {})
      return super if string.nil?

      normalized = string.delete(PASTE_CHARACTERS).unicode_normalize(:nfc)
      characters = normalized.each_char.uniq.grep_v(LAYOUT_CHARACTER)
      unsupported = characters.find { |character| !character.match?(SUPPORTED_CHARACTER) || character.match?(NON_PRINTING) }
      raise unsupported_text(unsupported) if unsupported

      style = options.fetch(:style, :normal)
      font(LATIN_FONT, style: style) do
        missing = characters.reject { |character| font.glyph_present?(character) }
        verify_cjk_coverage!(missing, style) if missing.any?
        super(normalized, options.merge(fallback_fonts: missing.empty? ? [] : [CJK_FONT]))
      end
    end

    private

    def verify_cjk_coverage!(characters, style)
      font(CJK_FONT, style: style) do
        missing = characters.find { |character| !font.glyph_present?(character) }
        raise unsupported_text(missing) if missing
      end
    end

    def font_files(name)
      {
        normal: FONT_ROOT.join("#{name}-Regular.ttf").to_s,
        bold: FONT_ROOT.join("#{name}-Bold.ttf").to_s
      }
    end

    def unsupported_text(character)
      reason = :unsupported_letter_text
      unsupported_codepoint = format('U+%04X', character.ord)
      message = EmailDelivery::ControlPanel.reason_text(reason, unsupported_codepoint: unsupported_codepoint)
      EmailDelivery::ConfigurationError.new(message, reason: reason, unsupported_codepoint: unsupported_codepoint)
    end
  end
end
