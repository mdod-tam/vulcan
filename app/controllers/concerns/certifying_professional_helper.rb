# frozen_string_literal: true

# Builds ApplicationDataStructures::CertifyingProfessionalInfo objects from an application or from parameters,
# and validates them.
module CertifyingProfessionalHelper
  extend ActiveSupport::Concern

  private

  # Creates a CertifyingProfessionalInfo object from application data
  # @param application [Application] The application to extract provider info from
  # @return [ApplicationDataStructures::CertifyingProfessionalInfo] Certifying professional object
  def certifying_professional_from_application(application)
    ApplicationDataStructures::CertifyingProfessionalInfo.new(
      name: application.certifying_professional_name,
      phone: application.certifying_professional_phone,
      fax: application.certifying_professional_fax,
      email: application.certifying_professional_email
    )
  end

  # Creates a CertifyingProfessionalInfo object from parameters
  # @param params_hash [Hash] Parameters containing certifying professional fields
  # @return [ApplicationDataStructures::CertifyingProfessionalInfo] Certifying professional object
  def certifying_professional_from_params(params_hash)
    ApplicationDataStructures::CertifyingProfessionalInfo.new(
      name: params_hash[:certifying_professional_name],
      phone: params_hash[:certifying_professional_phone],
      fax: params_hash[:certifying_professional_fax],
      email: params_hash[:certifying_professional_email]
    )
  end

  # Creates a CertifyingProfessionalInfo object with fallback logic (params first, then application)
  # @param params_hash [Hash] Parameters containing certifying professional fields
  # @param application [Application] Application to fallback to for missing fields
  # @return [ApplicationDataStructures::CertifyingProfessionalInfo] Certifying professional object
  def certifying_professional_with_fallback(params_hash, application)
    ApplicationDataStructures::CertifyingProfessionalInfo.new(
      name: params_hash[:certifying_professional_name] || application.certifying_professional_name,
      phone: params_hash[:certifying_professional_phone] || application.certifying_professional_phone,
      fax: params_hash[:certifying_professional_fax] || application.certifying_professional_fax,
      email: params_hash[:certifying_professional_email] || application.certifying_professional_email
    )
  end

  # Validates a certifying professional and returns error messages
  # @param provider [ApplicationDataStructures::CertifyingProfessionalInfo] Provider to validate
  # @return [Array<String>] Array of error messages (empty if valid)
  def validate_certifying_professional(provider)
    errors = []
    errors << 'Certifying professional name is required' if provider.name.blank?
    errors << 'Certifying professional phone is required' if provider.phone.blank?
    errors << 'Certifying professional email is required' if provider.email.blank?
    errors << 'Invalid phone number format' if provider.phone.present? && !provider.valid_phone?
    errors << 'Invalid email format' if provider.email.present? && !provider.valid_email?
    errors
  end
end
