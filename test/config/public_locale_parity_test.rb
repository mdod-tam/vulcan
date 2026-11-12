# frozen_string_literal: true

require 'test_helper'

# Public and constituent flows resolve messages in the person's locale, so every message they reach needs a Spanish
# entry. Admin and vendor alerts are English-only on purpose (see the comment above alerts: in es.yml) and stay out
# of these scopes.
class PublicLocaleParityTest < ActiveSupport::TestCase
  SCOPES = %w[
    alerts.sign_in_required alerts.session_expired alerts.session_fail
    application_notifications.proof_approved application_notifications.registration_confirmation
    applications.alternate_contact_relationship_types applications.creation constituent_portal.activity controllers errors.messages layouts.secure_public
    constituent_portal.dependents constituent_portal.proofs notifications.messages notifications.proof_copy notifications.index
    passwords password_visibility portal_self_service sessions terms_and_conditions
    secure_certification_form_resends secure_certification_forms secure_proof_form_resends secure_proof_forms
    secure_provider_info_form_resends secure_provider_info_forms secure_w9_form_resends secure_w9_forms
    security_key_verification shared.date_of_birth shared.header shared.password support.array two_factor_verification
  ].freeze

  SCOPES.each do |scope|
    test "#{scope} has matching English and Spanish keys, value types, and interpolation arguments" do
      store = I18n.backend.translations(do_init: true)
      english, spanish = %i[en es].map do |locale|
        node = store.fetch(locale).dig(*scope.split('.').map(&:to_sym))
        assert_not_nil node, "#{locale} has no #{scope}"
        translation_leaves(node, scope)
      end

      assert_equal translation_contract(english), translation_contract(spanish), "Translation contracts differ for #{scope}"
      assert_equal [], spanish.select { |_key, value| value.is_a?(String) && value.empty? }.keys,
                   "Spanish translations are empty for #{scope}"
    end
  end

  private

  def translation_leaves(node, prefix)
    return { prefix => node } unless node.is_a?(Hash)

    node.each_with_object({}) { |(key, value), leaves| leaves.merge!(translation_leaves(value, "#{prefix}.#{key}")) }
  end

  def translation_contract(leaves)
    leaves.transform_values do |value|
      [value.class, value.is_a?(String) ? interpolation_arguments(value) : nil]
    end
  end

  def interpolation_arguments(text)
    text.scan(/%\{(\w+)\}/).flatten.sort
  end
end
