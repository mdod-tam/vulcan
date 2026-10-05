# frozen_string_literal: true

# Controller adapters for user creation and guardian relationships.
module UserServiceIntegration
  extend ActiveSupport::Concern

  # Returns the result from UserCreationService.
  # @param user_params [Hash, ActionController::Parameters] The user parameters
  # @param is_managing_adult [Boolean] True for a guardian, false for a dependent
  # @param skip_user_lookup [Boolean] If true, attempts creation without an existing-user lookup
  # @param require_disability_validation [Boolean] If true, requires at least one selected disability for a new user
  # @return [BaseService::Result] The service result
  def create_user_with_service(user_params, is_managing_adult: false, skip_user_lookup: false,
                               require_disability_validation: false, skip_email_validation: false,
                               skip_phone_validation: false)
    attrs = user_params.respond_to?(:to_h) ? user_params.to_h : user_params

    service = Applications::UserCreationService.new(attrs,
                                                    is_managing_adult: is_managing_adult,
                                                    skip_user_lookup: skip_user_lookup,
                                                    require_disability_validation: require_disability_validation,
                                                    skip_email_validation: skip_email_validation,
                                                    skip_phone_validation: skip_phone_validation)
    service.call
  end

  # Delegates relationship creation to GuardianDependentManagementService.
  # @param guardian_user [User] The guardian user
  # @param dependent_user [User] The dependent user
  # @param relationship_type [String] The type of relationship
  # @param contact_strategies [Hash] Email, phone, and address strategies (defaults to 'dependent')
  # @return [Boolean] Whether the relationship was created successfully
  def create_guardian_relationship_with_service(guardian_user, dependent_user, relationship_type,
                                                contact_strategies: {}, portal_creation_key: nil,
                                                portal_creation_fingerprint: nil)
    default_strategies = {
      email_strategy: 'dependent',
      phone_strategy: 'dependent',
      address_strategy: 'dependent'
    }

    relationship_params = {
      applicant_type: 'dependent',
      relationship_type: relationship_type,
      portal_creation_key: portal_creation_key,
      portal_creation_fingerprint: portal_creation_fingerprint
    }.merge(default_strategies.merge(contact_strategies))

    service = Applications::GuardianDependentManagementService.new(
      relationship_params,
      guardian_user: guardian_user,
      dependent_user: dependent_user
    )

    service.create_guardian_relationship(relationship_type)
  end

  # @param errors [Object] Can be ActiveModel::Errors, Array, or String
  # @return [Array<String>] Array of error message strings
  def extract_error_messages(errors)
    if errors.respond_to?(:full_messages)
      errors.full_messages
    elsif errors.is_a?(Array)
      errors
    else
      [errors.to_s]
    end
  end

  # @param context [String] Context description (e.g., "creating dependent")
  # @param errors [Object] The errors to log
  def log_user_service_error(context, errors)
    error_messages = extract_error_messages(errors)
    Rails.logger.error "Failed #{context}: #{error_messages.join(', ')}"
  end
end
