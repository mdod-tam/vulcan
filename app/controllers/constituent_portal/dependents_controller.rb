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
      # Using UserServiceIntegration concern for consistent user creation
      # Flow: create_user_with_service(params, is_managing_adult: false) -> handles password, disability validation, etc.
      result = create_user_with_service(dependent_user_params, is_managing_adult: false)

      if result.success?
        @dependent_user = result.data[:user]

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
      params_to_update = dependent_user_params
      configure_uniqueness_validation(params_to_update)

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
      # Ensure current_user can only manage their own dependents
      @dependent = current_user.dependents.find_by(id: params[:id])
      redirect_to constituent_portal_dashboard_path, alert: 'Dependent not found.' unless @dependent
    end

    def dependent_user_params
      # Define strong parameters for the dependent User
      # Ensure to permit all necessary fields for creating a User (e.g., email, name, dob)
      # Handle password creation strategy for dependents (e.g., generate random, or no login)
      params.expect(dependent: %i[first_name last_name email phone phone_type date_of_birth
                                  hearing_disability vision_disability
                                  speech_disability mobility_disability cognition_disability])
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

    def configure_uniqueness_validation(params_to_update)
      should_skip_validation = should_skip_uniqueness_validation?(params_to_update)
      @dependent.skip_contact_uniqueness_validation = true if should_skip_validation
    end

    def should_skip_uniqueness_validation?(params_to_update)
      params_to_update[:email] == current_user.email ||
        params_to_update[:phone] == current_user.phone ||
        @dependent.email == current_user.email ||
        @dependent.phone == current_user.phone
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
