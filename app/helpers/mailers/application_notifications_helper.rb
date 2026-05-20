# frozen_string_literal: true

module Mailers
  module ApplicationNotificationsHelper
    def format_proof_type(proof_type)
      return '' if proof_type.nil?

      type_value = proof_type.respond_to?(:proof_type_before_type_cast) ? proof_type.proof_type_before_type_cast : proof_type

      normalized_type = case type_value.to_s
                        when '0', 'income'
                          'income'
                        when '1', 'residency'
                          'residency'
                        when '3', 'id'
                          'id'
                        else
                          type_value.to_s
                        end

      I18n.t(
        "secure_proof_forms.proof_types.#{normalized_type}",
        default: normalized_type.humanize.downcase
      )
    end
  end
end
