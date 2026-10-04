# frozen_string_literal: true

module ParamCasting
  extend ActiveSupport::Concern

  BOOLEAN_FIELDS = %w[
    maryland_resident
    terms_accepted
    information_verified
    medical_release_authorized
    self_certify_disability
    hearing_disability
    vision_disability
    speech_disability
    mobility_disability
    cognition_disability
    use_guardian_email
    use_guardian_phone
    use_guardian_address
  ].freeze

  APPLICATION_BOOLEAN_FIELDS = %w[
    maryland_resident
    terms_accepted
    information_verified
    medical_release_authorized
    self_certify_disability
  ].freeze

  USER_DISABILITY_FIELDS = %w[
    self_certify_disability
    hearing_disability
    vision_disability
    speech_disability
    mobility_disability
    cognition_disability
  ].freeze

  STRATEGY_CHECKBOX_FIELDS = %w[
    use_guardian_email
    use_guardian_phone
    use_guardian_address
  ].freeze

  def cast_boolean_params
    return unless params[:application]

    cast_boolean_for(params[:application], APPLICATION_BOOLEAN_FIELDS + USER_DISABILITY_FIELDS)
  end

  def cast_complex_boolean_params
    cast_application_booleans
    cast_nested_user_booleans
    cast_strategy_checkboxes
  end

  # Empty strings and nil remain nil. Other values use Rails boolean rules.
  # @param value [Object] The value to cast
  # @return [Boolean, nil] The cast value
  def to_boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  alias safe_boolean_cast to_boolean

  private

  def cast_application_booleans
    return if params[:application].blank?

    cast_boolean_for(params[:application], APPLICATION_BOOLEAN_FIELDS + USER_DISABILITY_FIELDS)
  end

  def cast_nested_user_booleans
    nested_params = %i[applicant_attributes guardian_attributes constituent]

    nested_params.each do |param_key|
      next if params[param_key].blank?

      cast_boolean_for(params[param_key], USER_DISABILITY_FIELDS)
    end
  end

  def cast_strategy_checkboxes
    STRATEGY_CHECKBOX_FIELDS.each do |checkbox_param|
      next if params[checkbox_param].blank?

      params[checkbox_param] = to_boolean(params[checkbox_param])
    end
  end

  # @param hash [ActionController::Parameters, Hash] The parameter hash to modify
  # @param fields [Array<String>] The field names to cast
  def cast_boolean_for(hash, fields)
    return unless hash.is_a?(ActionController::Parameters) || hash.is_a?(Hash)

    fields.each do |field|
      field_sym = field.to_sym
      next unless hash.key?(field_sym)

      value = hash[field_sym]
      # A blank hidden value can precede the selected checkbox value.
      value = value.last if value.is_a?(Array) && value.size == 2 && value.first.blank?
      hash[field_sym] = to_boolean(value)
    end
  end
end
