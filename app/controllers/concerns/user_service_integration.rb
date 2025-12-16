# frozen_string_literal: true

# Provides helper methods for integrating with UserCreationService and GuardianDependentManagementService
# Can be included in controllers that need to create users or manage guardian/dependent relationships
module UserServiceIntegration
  extend ActiveSupport::Concern

  # Creates a user using UserCreationService with consistent error handling
  # @param user_params [Hash, ActionController::Parameters] The user parameters
  # @param is_managing_adult [Boolean] Whether this is a managing adult (guardian) or dependent
  # @param skip_user_lookup [Boolean] If true, always creates new user instead of finding existing (for portal)
  # @param require_disability_validation [Boolean] If true, validates at least one disability is selected
  # @return [BaseService::Result] The service result
  def create_user_with_service(user_params, is_managing_adult: false, skip_user_lookup: false, require_disability_validation: false)
    # Convert ActionController::Parameters to hash if needed
    attrs = user_params.respond_to?(:to_h) ? user_params.to_h : user_params
    attrs = attrs.with_indifferent_access if attrs.respond_to?(:with_indifferent_access)

    service = Applications::UserCreationService.new(attrs,
                                                    is_managing_adult: is_managing_adult,
                                                    skip_user_lookup: skip_user_lookup,
                                                    require_disability_validation: require_disability_validation)
    service.call
  end

  # Creates a guardian/dependent relationship using GuardianDependentManagementService
  # @param guardian_user [User] The guardian user
  # @param dependent_user [User] The dependent user
  # @param relationship_type [String] The type of relationship
  # @param contact_strategies [Hash] Email, phone, and address strategies (defaults to 'dependent')
  # @return [Boolean] Whether the relationship was created successfully
  def create_guardian_relationship_with_service(guardian_user, dependent_user, relationship_type, contact_strategies: {})
    default_strategies = {
      email_strategy: 'dependent',
      phone_strategy: 'dependent',
      address_strategy: 'dependent'
    }

    relationship_params = {
      applicant_type: 'dependent',
      relationship_type: relationship_type
    }.merge(default_strategies.merge(contact_strategies))

    service = Applications::GuardianDependentManagementService.new(relationship_params)
    service.instance_variable_set(:@guardian_user, guardian_user)
    service.instance_variable_set(:@dependent_user, dependent_user)

    service.create_guardian_relationship(relationship_type)
  end

  # Extracts error messages from various error sources
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

  # Logs user creation/relationship errors consistently
  # @param context [String] Context description (e.g., "creating dependent")
  # @param errors [Object] The errors to log
  def log_user_service_error(context, errors)
    error_messages = extract_error_messages(errors)
    Rails.logger.error "Failed #{context}: #{error_messages.join(', ')}"
  end
end
