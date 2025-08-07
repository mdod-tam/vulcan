# frozen_string_literal: true

module Admin
  class UsersController < ApplicationController
    include ParamCasting
    include UserServiceIntegration

    before_action :authenticate_user!
    before_action :require_admin!

    def index
      setup_index_parameters
      @users = build_index_query.limit(10).to_a

      respond_to do |format|
        format.html { handle_html_response }
        format.json { handle_json_response }
      end
    end

    # Setup parameters for index action
    def setup_index_parameters
      @q = params[:q]
      @role_filter = params[:role] # e.g., "guardian" or "dependent" from paper app form
      @frame_id = params[:turbo_frame_id] # e.g., "guardian_search_results"
    end

    # Build query for index action (DRY version of build_search_query)
    def build_index_query
      base_query = User.order(:type, :last_name, :first_name)

      if @q.present?
        apply_search_filter(base_query)
      elsif turbo_frame_request_for_search_results?
        base_query.none
      else
        base_query
      end
    end

    # Apply search filter to query (shared logic)
    def apply_search_filter(query)
      query_term = "%#{@q.downcase}%"
      query.where(
        'LOWER(first_name) ILIKE :q OR LOWER(last_name) ILIKE :q OR LOWER(email) ILIKE :q', q: query_term
      )
    end

    # Check if this is a turbo frame request for search results
    def turbo_frame_request_for_search_results?
      turbo_frame_request_id&.end_with?('_search_results')
    end

    # Handle HTML format response
    def handle_html_response
      if search_results_frame_request?
        render_search_results_partial
      elsif full_page_load_without_query?
        handle_full_page_load
      end
    end

    # Handle JSON format response
    def handle_json_response
      render json: @users.as_json(only: %i[id first_name last_name email])
    end

    # Check if this is a search results frame request
    def search_results_frame_request?
      turbo_frame_request_id == "#{@role_filter}_search_results" || @frame_id == "#{@role_filter}_search_results"
    end

    # Check if this is a full page load without query
    def full_page_load_without_query?
      @q.blank?
    end

    # Render search results partial
    def render_search_results_partial
      render partial: 'admin/users/user_search_results_list', locals: { users: @users, role: @role_filter }
    end

    # Handle full page load with all users
    def handle_full_page_load
      @users = User.order(:type, :last_name, :first_name).to_a
      optimize_users_for_index_view(@users)
    end

    def show
      @user = User.find(params[:id])
      return unless @user.is_a?(Users::Constituent)

      load_and_enhance_user_relationships
    end

    # Load and enhance user relationships for the show view
    def load_and_enhance_user_relationships
      relationship_data = load_user_relationships
      enhance_relationships_with_users(relationship_data)
      view_instance_variables(relationship_data)
      add_helper_methods_to_user(relationship_data)
    end

    # Load guardian relationships for a specific user
    def load_user_relationships
      dependent_rels = GuardianRelationship.where(guardian_id: @user.id)
                                           .select(:id, :guardian_id, :dependent_id, :relationship_type)
                                           .to_a

      guardian_rels = GuardianRelationship.where(dependent_id: @user.id)
                                          .select(:id, :guardian_id, :dependent_id, :relationship_type)
                                          .to_a

      { dependent_rels: dependent_rels, guardian_rels: guardian_rels }
    end

    # Enhance relationships with user objects
    def enhance_relationships_with_users(relationship_data)
      dependent_rels = relationship_data[:dependent_rels]
      guardian_rels = relationship_data[:guardian_rels]

      all_user_ids = dependent_rels.map(&:dependent_id) + guardian_rels.map(&:guardian_id)
      return unless all_user_ids.any?

      related_users = User.where(id: all_user_ids).index_by(&:id)
      attach_users_to_relationships(dependent_rels, guardian_rels, related_users)
    end

    # Attach user objects to relationship records
    def attach_users_to_relationships(dependent_rels, guardian_rels, related_users)
      dependent_rels.each do |rel|
        rel.define_singleton_method(:dependent_user) do
          related_users[rel.dependent_id]
        end
      end

      guardian_rels.each do |rel|
        rel.define_singleton_method(:guardian_user) do
          related_users[rel.guardian_id]
        end
      end
    end

    # Set instance variables for the view
    def view_instance_variables(relationship_data)
      dependent_rels = relationship_data[:dependent_rels]
      guardian_rels = relationship_data[:guardian_rels]

      @dependents_count = dependent_rels.size
      @has_guardian = guardian_rels.any?
      @guardian_relationships = guardian_rels
      @dependent_relationships = dependent_rels
    end

    # Add helper methods to the user instance (DRY version of enhance_user_with_relationship_data)
    def add_helper_methods_to_user(_relationship_data)
      @user.instance_variable_set(:@dependents_count, @dependents_count)
      @user.instance_variable_set(:@has_guardian, @has_guardian)

      add_relationship_helper_methods_to_user(@user)
    end

    # Add relationship helper methods to a user instance (shared with other methods)
    def add_relationship_helper_methods_to_user(user)
      class << user
        def dependents_count
          @dependents_count || 0
        end

        def guardian?
          (@dependents_count || 0).positive?
        end

        def dependent?
          @has_guardian || false
        end
      end
    end

    def edit
      @user = User.find(params[:id])
    end

    # Create action for creating a new guardian from the paper application form
    def create
      # Using UserServiceIntegration concern for consistent user creation
      # Flow: create_user_with_service(params, is_managing_adult: true) -> handles password generation, validation, etc.
      result = create_user_with_service(user_create_params, is_managing_adult: true)

      if result.success?
        user = result.data[:user]
        # Check for duplicates and set flag (UserCreationService handles basic creation, we add our admin-specific logic)
        user.update!(needs_duplicate_review: true) if potential_duplicate_found?(user)

        render json: {
          success: true,
          user: user.as_json(only: %i[id first_name last_name email phone
                                      physical_address_1 physical_address_2 city state zip_code])
        }
      else
        log_user_service_error('to create user in admin interface', result.data[:errors] || [result.message])
        render json: {
          success: false,
          errors: extract_error_messages(result.data[:errors] || [result.message])
        }, status: :unprocessable_content
      end
    end

    # New dedicated search endpoint for user search
    def search
      @q = params[:q]
      @role_filter = params[:role] # e.g., "guardian" or "dependent" from paper app form
      @frame_id = "#{@role_filter}_search_results"

      @users = build_search_query.limit(10).to_a
      enhance_constituent_users(@users)

      render partial: 'admin/users/user_search_results_list', locals: { users: @users, role: @role_filter }
    end

    # Define the mapping from expected demodulized names to full namespaced names.
    # These should match the actual class names under the Users module.
    VALID_USER_TYPES = {
      'Admin' => 'Users::Administrator',
      'Administrator' => 'Users::Administrator',
      'Evaluator' => 'Users::Evaluator',
      'Constituent' => 'Users::Constituent',
      'Vendor' => 'Users::Vendor',
      'Trainer' => 'Users::Trainer'
    }.freeze

    def update_role
      user = User.find(params[:id])
      Rails.logger.info "Admin::UsersController#update_role - Received raw params[:role]: #{params[:role].inspect} for user_id: #{user.id}"

      namespaced_role = validate_and_normalize_role(params[:role], user.id)
      return if performed? # Early return if validation failed and response was rendered

      unless can_update_user_role?(user, namespaced_role)
        render_self_update_error
        return
      end

      if role_unchanged?(user, namespaced_role)
        handle_unchanged_role(user, namespaced_role)
      else
        handle_role_change(user, namespaced_role)
      end
    end

    def update_capabilities
      @user = User.find(params[:id])
      capability = params[:capability]
      enabled = to_boolean(params[:enabled])

      if enabled
        handle_add_capability(capability)
      else
        handle_remove_capability(capability)
      end
    rescue StandardError => e
      handle_capability_error(e)
    end

    # Handle adding a capability to a user
    def handle_add_capability(capability)
      result = @user.add_capability(capability)
      log_capability_action('Adding', capability, result)

      if result.is_a?(RoleCapability)
        render_capability_success("Added #{capability.titleize} Capability")
      else
        error_message = extract_error_message(result)
        Rails.logger.error "Failed to add capability: #{error_message}"
        render_capability_error(error_message || 'Failed to add capability')
      end
    end

    # Handle removing a capability from a user
    def handle_remove_capability(capability)
      result = @user.remove_capability(capability)
      log_capability_action('Removing', capability, result)

      if result
        render_capability_success("Removed #{capability.titleize} Capability")
      else
        render_capability_error('Failed to remove capability')
      end
    end

    # Log capability action
    def log_capability_action(action, capability, result)
      Rails.logger.info "#{action} capability #{capability} to user #{@user.id}: #{result}"
    end

    # Extract error message from result object
    def extract_error_message(result)
      result.errors.full_messages.join(', ') if result.respond_to?(:errors)
    end

    # Render successful capability response
    def render_capability_success(message)
      render json: { message: message, success: true }
    end

    # Render capability error response
    def render_capability_error(message)
      render json: { message: message, success: false }, status: :unprocessable_content
    end

    # Handle capability operation errors
    def handle_capability_error(error)
      Rails.logger.error "Error in update_capabilities: #{error.message}\n#{error.backtrace.join("\n")}"
      render json: {
        success: false,
        message: error.message
      }, status: :unprocessable_content
    end

    def update
      @user = User.find(params[:id])

      if @user.update(admin_user_params)
        redirect_to admin_user_path(@user), notice: 'User was successfully updated.'
      else
        render :edit, status: :unprocessable_content
      end
    end

    def constituents
      @q = params[:q]
      scope = User.where(type: 'Constituent')
                  .joins(:applications)
                  .where(applications: { status: [Application.statuses[:rejected], Application.statuses[:archived]] })
                  .group('users.id')

      if @q.present?
        scope = scope.where("first_name ILIKE :q OR last_name ILIKE :q OR (first_name || ' ' || last_name) ILIKE :q",
                            q: "%#{@q}%")
      end

      @users = scope.order(:last_name)
    end

    def history
      @user = User.find(params[:id])
      @applications = @user.applications.order(application_date: :desc)
    end

    private

    # Build search query based on search parameters
    def build_search_query
      base_query = User.order(:last_name, :first_name)

      if @q.present?
        # Split search terms to handle multi-word searches like "Guardian Test"
        search_terms = @q.strip.split(/\s+/)

        if search_terms.length == 1
          # Single term search - search in first_name, last_name, or email
          query_term = "%#{search_terms.first.downcase}%"
          base_query.where(
            'LOWER(first_name) ILIKE :q OR LOWER(last_name) ILIKE :q OR LOWER(email) ILIKE :q', q: query_term
          )
        else
          # Multi-term search - try to match full name or individual terms
          full_name_term = "%#{@q.downcase}%"
          full_name_query = base_query.where(
            "LOWER(CONCAT(first_name, ' ', last_name)) ILIKE :q OR LOWER(email) ILIKE :q", q: full_name_term
          )

          return full_name_query unless full_name_query.empty?

          # If no results from full name search, try individual terms
          condition = build_multi_term_condition(search_terms)
          base_query.where(condition)
        end
      else
        # If no query, return empty results
        base_query.none
      end
    end

    # Build Arel condition for multi-term search
    def build_multi_term_condition(terms)
      table = User.arel_table
      terms.inject(nil) do |condition, term|
        term_pattern = "%#{term.downcase}%"
        term_cond = table[:first_name].lower.matches(term_pattern)
                                      .or(table[:last_name].lower.matches(term_pattern))
                                      .or(table[:email].lower.matches(term_pattern))

        condition ? condition.or(term_cond) : term_cond
      end
    end

    # Enhance constituent users with relationship data to avoid N+1 queries
    def enhance_constituent_users(users)
      constituent_ids = users.select { |user| user.is_a?(Users::Constituent) }.map(&:id)
      return unless constituent_ids.any?

      constituent_records = load_enhanced_constituents(constituent_ids)
      replace_users_with_enhanced_versions(users, constituent_records)
    end

    # Load constituent users with relationship data
    def load_enhanced_constituents(constituent_ids)
      constituent_records = {}
      relationship_data = load_relationship_data(constituent_ids)

      Users::Constituent.where(id: constituent_ids).find_each do |user|
        enhance_user_with_relationship_data(user, relationship_data)
        constituent_records[user.id] = user
      end

      constituent_records
    end

    # Load relationship data for constituents
    def load_relationship_data(constituent_ids)
      {
        dependents_counts: GuardianRelationship.where(guardian_id: constituent_ids)
                                               .group(:guardian_id)
                                               .count,
        has_guardian: GuardianRelationship.where(dependent_id: constituent_ids)
                                          .distinct
                                          .pluck(:dependent_id)
      }
    end

    # Enhance a single user with relationship data
    def enhance_user_with_relationship_data(user, relationship_data)
      user.instance_variable_set(:@dependents_count, relationship_data[:dependents_counts][user.id] || 0)
      user.instance_variable_set(:@has_guardian, relationship_data[:has_guardian].include?(user.id))

      # Add helper methods to access the data
      class << user
        def dependents_count
          @dependents_count || 0
        end

        def guardian?
          (@dependents_count || 0).positive?
        end

        def dependent?
          @has_guardian || false
        end
      end
    end

    # Replace users in array with enhanced versions
    def replace_users_with_enhanced_versions(users, constituent_records)
      users.each_with_index do |user, index|
        users[index] = constituent_records[user.id] if user.is_a?(Users::Constituent) && constituent_records[user.id]
      end
    end

    # Role update helper methods
    def validate_and_normalize_role(raw_role_param, user_id)
      return nil if raw_role_param.blank?

      namespaced_role = if raw_role_param.include?('::')
                          VALID_USER_TYPES.values.find { |v| v == raw_role_param }
                        else
                          VALID_USER_TYPES[raw_role_param.classify]
                        end

      if namespaced_role.blank?
        Rails.logger.warn "Admin::UsersController#update_role - Invalid role: #{raw_role_param.inspect} for user_id: #{user_id}"
        render json: {
          success: false,
          message: "Invalid role specified: '#{raw_role_param}'. Please select a valid role."
        }, status: :unprocessable_content
        return nil
      end

      Rails.logger.info "Admin::UsersController#update_role - Determined namespaced_role: #{namespaced_role.inspect} for user_id: #{user_id}"
      namespaced_role
    end

    def can_update_user_role?(user, namespaced_role)
      user.prevent_self_role_update?(current_user, namespaced_role)
    end

    def render_self_update_error
      Rails.logger.warn "Admin::UsersController#update_role - Denied self role change attempt by user_id: #{current_user.id}"
      render json: {
        success: false,
        message: 'You cannot change your own role.'
      }, status: :forbidden
    end

    def role_unchanged?(user, namespaced_role)
      user.type == namespaced_role
    end

    def handle_unchanged_role(user, namespaced_role)
      update_user_capabilities(user, params[:capabilities]) if params[:capabilities].present?
      Rails.logger.info "Admin::UsersController#update_role - Type #{user.type} not changed. Capabilities updated if provided."
      render json: {
        success: true,
        message: "#{user.full_name}'s role is already #{namespaced_role.demodulize.titleize}."
      }
    end

    def handle_role_change(user, namespaced_role)
      new_klass = validate_target_class(namespaced_role)
      return if performed? # Early return if validation failed

      converted_user = convert_user_to_new_type(user, new_klass)
      save_converted_user(converted_user, user)
    end

    def validate_target_class(namespaced_role)
      new_klass = namespaced_role.safe_constantize
      if new_klass.blank? || new_klass.ancestors.exclude?(User)
        Rails.logger.error "Admin::UsersController#update_role - Invalid target class for STI: #{namespaced_role}"
        render json: { success: false, message: 'Invalid target role class.' }, status: :unprocessable_content
        return nil
      end
      new_klass
    end

    def convert_user_to_new_type(user, new_klass)
      converted_user = user.becomes(new_klass)
      clear_type_specific_fields(user, converted_user)
      converted_user
    end

    def clear_type_specific_fields(original_user, converted_user)
      return unless original_user.type_was == 'Users::Vendor' && !converted_user.is_a?(Users::Vendor)

      Rails.logger.info "Admin::UsersController#update_role - Nullifying vendor-specific fields for user_id: #{original_user.id}"
      converted_user.business_name = nil
      converted_user.business_tax_id = nil
      converted_user.terms_accepted_at = nil
      converted_user.w9_status = nil

      # Add similar blocks for other types if they have type-specific fields
    end

    def save_converted_user(converted_user, original_user)
      if converted_user.save
        handle_successful_user_conversion(converted_user)
      else
        handle_failed_user_conversion(converted_user, original_user)
      end
    end

    def handle_successful_user_conversion(converted_user)
      update_user_capabilities(converted_user, params[:capabilities]) if params[:capabilities].present?
      log_successful_conversion(converted_user)
      render_conversion_success(converted_user)
    end

    def handle_failed_user_conversion(converted_user, original_user)
      log_failed_conversion(converted_user, original_user)
      render_conversion_error(converted_user)
    end

    def log_successful_conversion(converted_user)
      Rails.logger.info "Admin::UsersController#update_role - Successfully updated user_id: #{converted_user.id} to type: #{converted_user.type}"
    end

    def log_failed_conversion(converted_user, original_user)
      Rails.logger.error "Admin::UsersController#update_role - Failed to save converted_user_id: #{original_user.id} " \
                         "as type #{converted_user.type}: #{converted_user.errors.full_messages.join(', ')}"
    end

    def render_conversion_success(converted_user)
      render json: {
        success: true,
        message: "#{converted_user.full_name}'s role updated to #{converted_user.type.demodulize.titleize}."
      }
    end

    def render_conversion_error(converted_user)
      render json: {
        success: false,
        message: converted_user.errors.full_messages.join(', ')
      }, status: :unprocessable_content
    end

    def require_admin!
      redirect_to root_path, alert: 'Not authorized' unless current_user&.admin?
    end

    def user_params
      params.expect(user: [:type, { capabilities: [] }])
    end

    # Parameters for admin user edit form
    def admin_user_params
      params.expect(
        user: %i[first_name last_name email phone phone_type
                 physical_address_1 physical_address_2 city state zip_code
                 communication_preference]
      )
    end

    # Handles updating capabilities for a user
    # Used by update_role to ensure capabilities are maintained when changing user types
    def update_user_capabilities(user, capabilities)
      return if capabilities.blank?

      # Clear existing capabilities first
      user.role_capabilities.destroy_all

      # Add each new capability
      capabilities.each do |capability|
        user.add_capability(capability)
      end
    end

    # Permits parameters for creating a constituent user
    # Called in the create action
    def user_create_params
      # When called from the admin UI (normal user create form), parameters come wrapped in :user
      # When called from the paper application form, parameters come directly (unwrapped)
      if params.key?(:user)
        params.expect(
          user: %i[first_name last_name email phone phone_type
                   physical_address_1 physical_address_2
                   city state zip_code date_of_birth
                   communication_preference locale needs_duplicate_review]
        )
      else
        # Handle direct params from paper application form's guardian_attributes
        params.permit(
          :first_name, :last_name, :email, :phone, :phone_type,
          :physical_address_1, :physical_address_2,
          :city, :state, :zip_code, :date_of_birth,
          :communication_preference, :locale, :needs_duplicate_review
        )
      end
    end

    # Checks for possible duplicate users based on name and date of birth
    # Called in the create action to flag potential duplicates for review
    def potential_duplicate_found?(user)
      return false unless user.first_name.present? && user.last_name.present? && user.date_of_birth.present?

      query = User.where('LOWER(first_name) = ? AND LOWER(last_name) = ? AND date_of_birth = ?',
                         user.first_name.downcase,
                         user.last_name.downcase,
                         user.date_of_birth)

      # Exclude the current user if it has been persisted to avoid self-matching
      query = query.where.not(id: user.id) if user.persisted?

      query.exists?
    end

    # Avoid N+1 queries on users index
    def optimize_users_for_index_view(users)
      user_ids = users.map(&:id)
      return if user_ids.empty?

      preloaded_data = preload_user_index_data(user_ids)
      enhance_users_with_preloaded_data(users, preloaded_data)
    end

    # Preload all data needed for the users index view
    def preload_user_index_data(user_ids)
      {
        guardian_counts: load_guardian_counts(user_ids),
        has_guardian_ids: load_has_guardian_ids(user_ids),
        guardian_rels: load_guardian_relationships(user_ids),
        guardian_users: load_guardian_users(user_ids),
        capabilities_by_user: load_capabilities_by_user(user_ids)
      }
    end

    # Load guardian counts for users
    def load_guardian_counts(user_ids)
      GuardianRelationship.where(guardian_id: user_ids).group(:guardian_id).count
    end

    # Load IDs of users who have guardians
    def load_has_guardian_ids(user_ids)
      GuardianRelationship.where(dependent_id: user_ids).pluck(:dependent_id)
    end

    # Load guardian relationships grouped by dependent
    def load_guardian_relationships(user_ids)
      GuardianRelationship.where(dependent_id: user_ids).group_by(&:dependent_id)
    end

    # Load guardian users referenced in relationships
    def load_guardian_users(user_ids)
      guardian_rels = load_guardian_relationships(user_ids)
      guardian_user_ids = guardian_rels.values.flatten.map(&:guardian_id).uniq
      return {} unless guardian_user_ids.any?

      User.where(id: guardian_user_ids).index_by(&:id)
    end

    # Load capabilities grouped by user
    def load_capabilities_by_user(user_ids)
      RoleCapability.where(user_id: user_ids)
                    .pluck(:user_id, :capability)
                    .group_by(&:first)
                    .transform_values { |caps| caps.map(&:second) }
    end

    # Enhance users with preloaded data to avoid N+1 queries
    def enhance_users_with_preloaded_data(users, preloaded_data)
      users.each do |user|
        add_guardian_methods(user, preloaded_data)
        add_capability_methods(user, preloaded_data[:capabilities_by_user])
        add_role_methods(user)
      end
    end

    # Add guardian-related methods to user
    def add_guardian_methods(user, preloaded_data)
      guardian_counts = preloaded_data[:guardian_counts]
      has_guardian_ids = preloaded_data[:has_guardian_ids]
      guardian_rels = preloaded_data[:guardian_rels]
      guardian_users = preloaded_data[:guardian_users]

      user.define_singleton_method(:dependents_count) { guardian_counts[id] || 0 }
      user.define_singleton_method(:guardian?) { (guardian_counts[id] || 0).positive? }
      user.define_singleton_method(:dependent?) { has_guardian_ids.include?(id) }

      add_guardian_relationship_methods(user, guardian_rels, guardian_users)
    end

    # Add guardian relationship methods to user
    def add_guardian_relationship_methods(user, guardian_rels, guardian_users)
      user.define_singleton_method(:guardian_relationships_as_dependent) do
        rels = guardian_rels[id] || []
        # Set guardian_user for each relationship
        rels.each do |rel|
          rel.define_singleton_method(:guardian_user) do
            guardian_users&.fetch(guardian_id, nil)
          end
        end
        rels
      end

      user.define_singleton_method(:guardians) do
        guardian_relationships_as_dependent.map(&:guardian_user).compact
      end
    end

    # Add capability methods to user
    def add_capability_methods(user, capabilities_by_user)
      user.define_singleton_method(:has_capability?) do |capability|
        (capabilities_by_user[id] || []).include?(capability)
      end

      user.define_singleton_method(:available_capabilities) do
        Admin::UsersController.get_available_capabilities_for_user_type(type)
      end

      user.define_singleton_method(:inherent_capabilities) do
        Admin::UsersController.get_inherent_capabilities_for_user_type(type)
      end
    end

    # Add role methods to user
    def add_role_methods(user)
      user.define_singleton_method(:role_type) { type&.demodulize || 'Unknown' }
    end

    class << self
      # Get available capabilities for a user type
      def get_available_capabilities_for_user_type(user_type)
        case user_type
        when 'Users::Evaluator' then %w[can_evaluate]
        when 'Users::Trainer' then %w[can_train]
        when 'Users::Constituent' then %w[can_train can_evaluate]
        else
          []
        end
      end

      # Get inherent capabilities for a user type
      def get_inherent_capabilities_for_user_type(user_type)
        case user_type
        when 'Users::Evaluator' then %w[can_evaluate]
        when 'Users::Trainer' then %w[can_train]
        else
          []
        end
      end
    end
  end
end
