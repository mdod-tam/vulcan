# frozen_string_literal: true

require 'test_helper'

# Public flows render under the request locale, so every message they reach needs a Spanish entry. Admin and vendor
# alerts are English-only on purpose (see the comment above alerts: in es.yml) and stay out of these scopes.
class PublicLocaleParityTest < ActiveSupport::TestCase
  SCOPES = %w[
    alerts.sign_in_required alerts.session_expired alerts.session_fail
    controllers errors.messages layouts.secure_public
    passwords password_visibility portal_self_service sessions terms_and_conditions
    secure_certification_form_resends secure_certification_forms secure_proof_form_resends secure_proof_forms
    secure_provider_info_form_resends secure_provider_info_forms secure_w9_form_resends secure_w9_forms
    security_key_verification shared.date_of_birth shared.header shared.password two_factor_verification
  ].freeze

  SCOPES.each do |scope|
    test "#{scope} has matching English and Spanish keys, value types, and interpolation arguments" do
      store = I18n.backend.translations(do_init: true)
      english, spanish = %i[en es].map do |locale|
        node = store.fetch(locale).dig(*scope.split('.').map(&:to_sym))
        assert_not_nil node, "#{locale} has no #{scope}"
        translation_leaves(node, scope)
      end

      assert_equal english.keys.sort, spanish.keys.sort
      english.each do |key, text|
        translated = spanish.fetch(key)
        assert_equal text.class, translated.class, "Value type differs for #{key}"
        next unless text.is_a?(String)

        assert_equal interpolation_arguments(text), interpolation_arguments(translated), "Interpolation differs for #{key}"
        assert_not_empty translated, "Spanish translation is empty for #{key}"
      end
    end
  end

  private

  def translation_leaves(node, prefix)
    return { prefix => node } unless node.is_a?(Hash)

    node.each_with_object({}) { |(key, value), leaves| leaves.merge!(translation_leaves(value, "#{prefix}.#{key}")) }
  end

  def interpolation_arguments(text)
    text.scan(/%\{(\w+)\}/).flatten.sort
  end
end
