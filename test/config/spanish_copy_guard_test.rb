# frozen_string_literal: true

require 'test_helper'

# Catches defects a Spanish review keeps finding: text typed without accents, and English words left in a Spanish
# value. The word lists are short on purpose. Add a word when a review finds a new one.
class SpanishCopyGuardTest < ActiveSupport::TestCase
  # Singular forms only. The plurals ("sesiones", "capacitaciones") correctly lose the accent.
  UNACCENTED = /\b(?:sesion|capacitacion|expirara|vencera|dias|comuniquese|contrasena|informacion|electronico|telefono|direccion|verificacion|notificacion)\b/i
  ENGLISH = /\b(?:solely|the|and|your|please|click)\b/

  test 'Spanish locale values are accented and contain no English words' do
    offenders = spanish_values.flat_map do |key, value|
      text = value.gsub(/%\{\w+\}|\{\{[^}]*\}\}|https?:\S+|<[^>]+>/, ' ')
      [UNACCENTED, ENGLISH].filter_map { |pattern| "#{key}: #{text[pattern]}" if text.match?(pattern) }
    end

    assert_empty offenders
  end

  test 'Spanish email seeds are accented' do
    offenders = Rails.root.glob('db/seeds/email_templates/*_es.rb').filter_map do |path|
      word = path.read[UNACCENTED]
      "#{path.basename}: #{word}" if word
    end

    assert_empty offenders
  end

  private

  def spanish_values
    Rails.root.glob('config/locales/**/*.yml').flat_map do |path|
      leaves(YAML.load_file(path, aliases: true)['es'], path.basename.to_s)
    end
  end

  def leaves(node, prefix)
    case node
    when Hash then node.flat_map { |key, value| leaves(value, "#{prefix}.#{key}") }
    when Array then node.flat_map { |value| leaves(value, prefix) }
    when String then [[prefix, node]]
    else []
    end
  end
end
