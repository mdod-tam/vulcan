# frozen_string_literal: true

module ConstituentPortal
  class DependentsController < ApplicationController
    include UserServiceIntegration

    before_action :authenticate_user!
    before_action :require_constituent! # Ensure only constituents can manage dependents
    before_action :set_current_user
    before_action :set_dependent, only: %i[show edit update destroy]

    # GET /constituent_portal/dependents/:id
    def show
      # @dependent is set by before_action
      @guardian_relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      # Get recent profile changes for this dependent
      @recent_changes = get_recent_profile_changes(@dependent)

      # Get dependent's applications if any
      @dependent_applications = @dependent.applications.order(created_at: :desc).limit(5)
    end

    # GET /constituent_portal/dependents/new
    def new
      @dependent_user = User.new # For the dependent's user record
      @guardian_relationship = GuardianRelationship.new # For the relationship_type
    end

    # GET /constituent_portal/dependents/:id/edit
    def edit
      setup_edit_template_variables
    end

    # POST /constituent_portal/dependents
    def create
      dependent_attrs = dependent_attributes_with_contact_strategies
      unless dependent_attrs
        handle_creation_failure(contact_strategy_errors)
        return
      end

      # Using UserServiceIntegration concern for consistent user creation
      # Portal always creates NEW users for dependents (skip_user_lookup: true)
      # Paper applications may find/reuse existing users (skip_user_lookup: false, default)
      # Require disability validation for portal-created dependents
      result = create_user_with_service(dependent_attrs,
                                        is_managing_adult: false,
                                        skip_user_lookup: true,
                                        require_disability_validation: true)

      if result.success?
        @dependent_user = result.data[:user]

        # Safety check: Ensure the dependent is not the same as the guardian
        if @dependent_user.id == current_user.id
          @dependent_user.destroy if @dependent_user.persisted?
          log_user_service_error('to create dependent', 'Cannot add yourself as your own dependent')
          handle_creation_failure(['You cannot add yourself as your own dependent. Please create a dependent with different contact information.'])
          return
        end

        # Using UserServiceIntegration concern for relationship creation
        # Flow: create_guardian_relationship_with_service -> handles relationship creation and validation
        if create_guardian_relationship_with_service(current_user, @dependent_user, guardian_relationship_params[:relationship_type])
          redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully created.'
        else
          # Clean up the created user if relationship creation fails
          @dependent_user.destroy
          log_user_service_error('to create guardian relationship', 'Relationship creation failed')
          handle_creation_failure(['Failed to create guardian relationship'])
        end
      else
        log_user_service_error('to create dependent user', result.data[:errors] || [result.message])
        handle_creation_failure(result.data[:errors] || [result.message])
      end
    end

    # PATCH/PUT /constituent_portal/dependents/:id
    def update
      params_to_update = dependent_attributes_with_contact_strategies
      unless params_to_update
        contact_strategy_errors.each { |error| @dependent.errors.add(:base, error) }
        setup_edit_template_variables
        render :edit, status: :unprocessable_content
        return
      end

      if @dependent.update(params_to_update)
        redirect_after_successful_update
      else
        setup_edit_template_variables
        render :edit, status: :unprocessable_content
      end
    end

    # DELETE /constituent_portal/dependents/:id
    def destroy
      # @dependent is set by before_action
      # This should destroy the GuardianRelationship.
      # Destroying the dependent User record itself is more complex:
      # - Only if no other guardians?
      # - Only if no applications?
      # Focus on destroying the relationship from current_user's perspective.
      relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)

      if relationship&.destroy
        # Optionally, check if the dependent user should be destroyed
        # if !@dependent.guardians.exists? && !@dependent.applications.exists?
        #   @dependent.destroy
        # end
        redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully removed.'
      else
        redirect_to constituent_portal_dashboard_path, alert: 'Failed to remove dependent.'
      end
    end

    private

    def set_dependent
      # Use Rails-centric scope for authorization
      @dependent = User.editable_by_guardian(current_user).find_by(id: params[:id])

      return if @dependent

      redirect_to constituent_portal_dashboard_path, alert: 'Dependent not found.'
    end

    def dependent_user_params
      # Define strong parameters for the dependent User
      # Ensure to permit all necessary fields for creating a User (e.g., email, name, dob)
      # Handle password creation strategy for dependents (e.g., generate random, or no login)
      params.expect(dependent: %i[first_name last_name email phone phone_type date_of_birth
                                  hearing_disability vision_disability
                                  speech_disability mobility_disability cognition_disability
                                  newsletter_signup])
    end

    def guardian_relationship_params
      params.expect(guardian_relationship: [:relationship_type])
    end

    def require_constituent!
      return if current_user&.constituent?

      redirect_to root_path, alert: 'Access denied. Constituent-only area.'
    end

    def set_current_user
      Current.user = current_user
    end

    def dependent_attributes_with_contact_strategies
      attrs = dependent_user_params.to_h
      # Portal contact strategies snapshot the submitted choice into User fields.
      # Omitted contact keys preserve existing contact on partial updates.
      strategies = dependent_contact_strategy_params(attrs)
      return attrs if strategies.values_at(:email_strategy, :phone_strategy).all?(&:nil?)

      Applications::GuardianDependentManagementService
        .new(strategies)
        .tap { |service| @contact_strategy_service = service }
        .apply_contact_strategies_for(current_user, attrs)
    ensure
      @contact_strategy_errors = @contact_strategy_service&.errors if @contact_strategy_service&.errors&.any?
    end

    def contact_strategy_errors
      @contact_strategy_errors.presence || ['Unable to apply dependent contact strategy']
    end

    def dependent_contact_strategy_params(attrs)
      {
        email_strategy: contact_strategy_for(:email, :use_guardian_email, attrs),
        phone_strategy: contact_strategy_for(:phone, :use_guardian_phone, attrs),
        address_strategy: 'dependent'
      }
    end

    def contact_strategy_for(field, checkbox_param, attrs)
      submitted = attrs.key?(field) || attrs.key?(field.to_s)
      value = attrs[field] || attrs[field.to_s]

      # Update only rewrites contact when the field was submitted; omitted keys preserve stored values.
      if action_name == 'update'
        return nil unless submitted
      elsif !submitted
        return guardian_contact_strategy(checkbox_param, nil)
      end

      guardian_contact_strategy(checkbox_param, value)
    end

    def guardian_contact_strategy(param_name, dependent_value)
      return 'guardian' if ActiveModel::Type::Boolean.new.cast(params[param_name])
      # Submitted blank contact on create/update applies guardian strategy and regenerates primary contact.
      return 'guardian' if dependent_value.blank?
      return 'guardian' if matches_guardian_contact?(param_name, dependent_value)

      'dependent'
    end

    def matches_guardian_contact?(param_name, dependent_value)
      case param_name
      when :use_guardian_email
        User.normalize_email(dependent_value) == User.normalize_email(current_user.email)
      when :use_guardian_phone
        normalized_phone_digits(dependent_value) == normalized_phone_digits(current_user.phone)
      else
        false
      end
    end

    def normalized_phone_digits(phone)
      phone.to_s.gsub(/\D/, '')
    end

    # Get recent profile changes for a user
    def get_recent_profile_changes(user)
      Event.where(
        "(action = 'profile_updated' AND user_id = ?) OR (action = 'profile_updated_by_guardian' AND metadata->>'user_id' = ?)",
        user.id, user.id.to_s
      ).order(created_at: :desc).limit(10)
    end

    def handle_creation_failure(errors)
      # Handle both array of strings and ActiveModel::Errors objects
      error_messages = if errors.respond_to?(:full_messages)
                         errors.full_messages
                       elsif errors.is_a?(Array)
                         errors
                       else
                         [errors.to_s]
                       end

      error_prefix = Rails.env.test? ? '[TEST_VALIDATION] ' : ''
      Rails.logger.error "#{error_prefix}Failed to create dependent: #{error_messages.join(', ')}"

      # Set up form variables for re-rendering
      @dependent_user ||= User.new(dependent_user_params)
      @guardian_relationship ||= GuardianRelationship.new(guardian_relationship_params)

      flash.now[:alert] = "Failed to create dependent: #{error_messages.join(', ')}"
      render :new, status: :unprocessable_content
    end

    def redirect_after_successful_update
      if params[:application_id].present?
        app = Application.find_by(id: params[:application_id])
        if app
          return redirect_to constituent_portal_application_path(app),
                             notice: 'Dependent was successfully updated.'
        end
      end

      redirect_to constituent_portal_dashboard_path, notice: 'Dependent was successfully updated.'
    end

    def setup_edit_template_variables
      @dependent_user = @dependent
      @guardian_relationship = @dependent.guardian_relationships_as_dependent.find_by(guardian_user: current_user)
      @recent_changes = get_recent_profile_changes(@dependent)
    end
  end
end
