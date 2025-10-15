# frozen_string_literal: true

module Applications
  class AutosaveService < BaseService
    attr_reader :current_user, :params

    def initialize(current_user:, params:)
      super()
      @current_user = current_user
      @params = params
    end

    def call
      return autosave_error_result('Field name is required') if field_name.blank?
      return autosave_error_result('File uploads are not supported for autosave') if file_field?

      initialize_application
      save_field
    end

    private

    def field_name
      @field_name ||= params[:field_name]
    end

    def field_value
      @field_value ||= params[:field_value]
    end

    def file_field?
      field_name.ends_with?('proof]') || field_name.include?('file')
    end

    def initialize_application
      @application = if params[:id].present?
                       find_existing_application
                     else
                       find_or_create_draft_application
                     end
    end

    def find_existing_application
      current_user.applications.find_by(id: params[:id]) || find_or_create_draft_application
    end

    def find_or_create_draft_application
      # Determine if this is for a dependent based on params
      # Could come from multiple sources: user_id param or nested application[user_id]
      dependent_id = params[:user_id].presence || params.dig(:application, :user_id).presence

      # Build query to find existing draft
      # For dependent applications: match both user_id (the dependent) and managing_guardian_id (current user)
      # For self applications: match user_id and no managing_guardian_id
      draft_query = Application.draft.order(created_at: :desc)

      draft_query = if dependent_id.present?
                      # Looking for a dependent's draft application managed by current user
                      draft_query.where(user_id: dependent_id, managing_guardian_id: current_user.id)
                    else
                      # Looking for current user's own draft application (not as a guardian)
                      draft_query.where(user_id: current_user.id, managing_guardian_id: nil)
                    end

      existing_draft = draft_query.first

      # Return existing draft if found, otherwise create new
      return existing_draft if existing_draft

      # Check for active application before creating new draft
      # This prevents creating drafts when user already has submitted/processing application
      target_user_id = dependent_id || current_user.id
      active_application = Application.active_for_constituent(target_user_id).first
      return nil if active_application

      create_new_application(dependent_id)
    end

    def create_new_application(dependent_id = nil)
      current_user.applications.new.tap do |app|
        apply_default_attributes(app)

        # Set up dependent relationship if this is for a dependent
        if dependent_id.present?
          app.user_id = dependent_id
          app.managing_guardian_id = current_user.id
        end
      end
    end

    def apply_default_attributes(app)
      app.status = :draft
      app.application_date = Time.current
      app.submission_method = :online
      app.application_type ||= :new
    end

    def save_field
      attribute_name = extract_attribute_name
      target_model, actual_attribute = determine_target_model_and_attribute(attribute_name)

      result = if target_model == :user
                 save_user_field(actual_attribute)
               elsif target_model == :ignored
                 { success: false, errors: { field_name => ['This field cannot be autosaved'] } }
               else
                 save_application_field(actual_attribute)
               end

      result[:success] ? autosave_success_result : result
    end

    def extract_attribute_name
      # Handle nested medical provider attributes
      if field_name.include?('medical_provider_attributes') &&
         field_name =~ /medical_provider_attributes\]\[([^\]]+)\]/
        return "medical_provider_#{::Regexp.last_match(1)}"
      end

      # Handle standard application fields
      return field_name[12..-2] if field_name.start_with?('application[') && field_name.end_with?(']')

      field_name
    end

    def determine_target_model_and_attribute(attribute_name)
      user_fields = %w[hearing_disability vision_disability speech_disability
                       mobility_disability cognition_disability]
      ignored_fields = %w[physical_address_1 physical_address_2 city state zip_code
                          residency_proof income_proof]

      if user_fields.include?(attribute_name)
        [:user, attribute_name]
      elsif ignored_fields.include?(attribute_name)
        [:ignored, attribute_name]
      else
        [:application, attribute_name]
      end
    end

    def save_user_field(attribute)
      value = cast_user_field_value(attribute, field_value)
      current_user.update_column(attribute, value)
      @application.update_column(:last_visited_step, attribute) if @application.persisted?
      { success: true }
    rescue StandardError => e
      Rails.logger.error("Error autosaving user field #{attribute}: #{e.message}")
      { success: false, errors: { "application[#{attribute}]" => [e.message] } }
    end

    def save_application_field(attribute)
      validation_result = validate_field_value(attribute)
      return validation_result unless validation_result[:success]

      processed_value = cast_application_field_value(attribute, field_value)

      begin
        @application.assign_attributes(attribute => processed_value)
      rescue ActiveRecord::UnknownAttributeError
        return autosave_error_result('This field cannot be autosaved')
      end

      @application.valid?
      return { success: false, errors: { "application[#{attribute}]" => @application.errors[attribute] } } if @application.errors[attribute].any?

      @application.save(validate: false)
      @application.update_column(:last_visited_step, attribute)
      { success: true }
    rescue StandardError => e
      Rails.logger.error("Error autosaving application field #{attribute}: #{e.message}")
      { success: false, errors: { "application[#{attribute}]" => [e.message] } }
    end

    def cast_user_field_value(attribute, value)
      if %w[hearing_disability vision_disability speech_disability
            mobility_disability cognition_disability].include?(attribute)
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value
      end
    end

    def cast_application_field_value(attribute, value)
      if %w[maryland_resident self_certify_disability].include?(attribute)
        ActiveModel::Type::Boolean.new.cast(value)
      else
        value
      end
    end

    def validate_field_value(attribute)
      case attribute
      when 'annual_income'
        return autosave_error_result('Must be a valid number') unless field_value.to_s.match?(/\A\d+(\.\d+)?\z/)
      when 'household_size'
        return autosave_error_result('Must be a valid integer') unless field_value.to_s.match?(/\A\d+\z/)
      end

      { success: true }
    end

    def autosave_success_result
      { success: true, application_id: @application.id, message: 'Field saved successfully' }
    end

    def autosave_error_result(message)
      { success: false, errors: { base: [message] } }
    end
  end
end
