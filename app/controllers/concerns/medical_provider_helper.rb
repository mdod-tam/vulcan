# frozen_string_literal: true

# Builds ApplicationDataStructures::MedicalProviderInfo objects from an application or from parameters,
# and validates them.
module MedicalProviderHelper
  extend ActiveSupport::Concern

  private

  # Creates a MedicalProviderInfo object from application data
  # @param application [Application] The application to extract provider info from
  # @return [ApplicationDataStructures::MedicalProviderInfo] Medical provider object
  def medical_provider_from_application(application)
    ApplicationDataStructures::MedicalProviderInfo.new(
      name: application.medical_provider_name,
      phone: application.medical_provider_phone,
      fax: application.medical_provider_fax,
      email: application.medical_provider_email
    )
  end

  # Creates a MedicalProviderInfo object from parameters
  # @param params_hash [Hash] Parameters containing medical provider fields
  # @return [ApplicationDataStructures::MedicalProviderInfo] Medical provider object
  def medical_provider_from_params(params_hash)
    ApplicationDataStructures::MedicalProviderInfo.new(
      name: params_hash[:medical_provider_name],
      phone: params_hash[:medical_provider_phone],
      fax: params_hash[:medical_provider_fax],
      email: params_hash[:medical_provider_email]
    )
  end

  # Creates a MedicalProviderInfo object with fallback logic (params first, then application)
  # @param params_hash [Hash] Parameters containing medical provider fields
  # @param application [Application] Application to fallback to for missing fields
  # @return [ApplicationDataStructures::MedicalProviderInfo] Medical provider object
  def medical_provider_with_fallback(params_hash, application)
    ApplicationDataStructures::MedicalProviderInfo.new(
      name: params_hash[:medical_provider_name] || application.medical_provider_name,
      phone: params_hash[:medical_provider_phone] || application.medical_provider_phone,
      fax: params_hash[:medical_provider_fax] || application.medical_provider_fax,
      email: params_hash[:medical_provider_email] || application.medical_provider_email
    )
  end

  # Validates a medical provider and returns error messages
  # @param provider [ApplicationDataStructures::MedicalProviderInfo] Provider to validate
  # @return [Array<String>] Array of error messages (empty if valid)
  def validate_medical_provider(provider)
    errors = []
    errors << 'Medical provider name is required' if provider.name.blank?
    errors << 'Medical provider phone is required' if provider.phone.blank?
    errors << 'Medical provider email is required' if provider.email.blank?
    errors << 'Invalid phone number format' if provider.phone.present? && !provider.valid_phone?
    errors << 'Invalid email format' if provider.email.present? && !provider.valid_email?
    errors
  end
end
