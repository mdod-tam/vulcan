# frozen_string_literal: true

# Controller adapters for user creation and guardian relationships.
module UserServiceIntegration
  extend ActiveSupport::Concern

  # Returns the Applications::UserCreationService result.
  def create_user_with_service(user_params, skip_user_lookup: false, require_disability_validation: false)
    attrs = user_params.respond_to?(:to_h) ? user_params.to_h : user_params

    Applications::UserCreationService.new(attrs,
                                          skip_user_lookup: skip_user_lookup,
                                          require_disability_validation: require_disability_validation).call
  end

  # Returns whether GuardianDependentManagementService created the relationship, with every contact strategy 'dependent'.
  def create_guardian_relationship_with_service(guardian_user, dependent_user, relationship_type,
                                                portal_creation_key: nil, portal_creation_fingerprint: nil)
    relationship_params = {
      applicant_type: 'dependent',
      relationship_type: relationship_type,
      email_strategy: 'dependent',
      phone_strategy: 'dependent',
      address_strategy: 'dependent',
      portal_creation_key: portal_creation_key,
      portal_creation_fingerprint: portal_creation_fingerprint
    }

    Applications::GuardianDependentManagementService.new(
      relationship_params,
      guardian_user: guardian_user,
      dependent_user: dependent_user
    ).create_guardian_relationship(relationship_type)
  end

  # Logs the context and the class of errors. A message or validation detail can carry PII, so neither is logged.
  def log_user_service_error(context, errors)
    Rails.logger.error "Failed #{context}: #{errors.class.name}"
  end
end
