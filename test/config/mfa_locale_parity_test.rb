# frozen_string_literal: true

require 'test_helper'

class MfaLocaleParityTest < ActiveSupport::TestCase
  %w[two_factor_verification security_key_verification].each do |namespace|
    test "#{namespace} has matching English and Spanish keys and interpolation arguments" do
      translations = %w[en es].map do |locale|
        data = YAML.load_file(Rails.root.join("config/locales/#{namespace}.#{locale}.yml"), aliases: true)
        translation_leaves(data.fetch(locale).fetch(namespace))
      end
      english, spanish = translations
      assert_equal english.keys.sort, spanish.keys.sort
      english.each do |key, text|
        assert_equal text.scan(/%\{(\w+)\}/).flatten.sort,
                     spanish.fetch(key).scan(/%\{(\w+)\}/).flatten.sort, "Interpolation differs for #{namespace}.#{key}"
        assert_not_empty spanish.fetch(key), "Spanish translation is empty for #{namespace}.#{key}"
      end
    end
  end

  private

  def translation_leaves(hash, prefix = nil)
    hash.each_with_object({}) do |(key, value), leaves|
      path = [prefix, key].compact.join('.')
      value.is_a?(Hash) ? leaves.merge!(translation_leaves(value, path)) : leaves[path] = value
    end
  end
end
