# frozen_string_literal: true

module Applications
  # Handles guardian/dependent user management for paper applications
  class GuardianDependentManagementService < BaseService
    SYNTHETIC_PHONE_RANDOM_SPACE = 10_000_000
    SYNTHETIC_PHONE_MAX_ATTEMPTS = 25

    attr_reader :params, :guardian_user, :dependent_user, :errors

    def initialize(params)
      super()
      @params = params.with_indifferent_access
      @guardian_user = nil
      @dependent_user = nil
      @guardian_temp_password = nil
      @dependent_temp_password = nil
      @errors = []
    end

    def process_guardian_scenario(guardian_id, new_guardian_attrs, applicant_data, relationship_type)
      return failure('Failed to setup guardian') unless setup_guardian(guardian_id, new_guardian_attrs)

      applicant_data = applicant_data.deep_dup
      return failure('Failed to apply contact strategies') unless apply_contact_strategies(applicant_data)

      return failure('Failed to create dependent') unless create_dependent?(applicant_data)
      return failure('Failed to create relationship') unless create_relationship(relationship_type)

      success(
        guardian: @guardian_user,
        dependent: @dependent_user,
        guardian_temp_password: @guardian_temp_password,
        dependent_temp_password: @dependent_temp_password
      )
    end

    def apply_contact_strategies(applicant_data)
      return true unless @guardian_user

      # Strategies snapshot request-time contact choices into User fields.
      return false unless apply_email_strategy(applicant_data)
      return false unless apply_phone_strategy(applicant_data)

      apply_address_strategy(applicant_data)
      true
    end

    def apply_contact_strategies_for(guardian_user, applicant_data)
      @guardian_user = guardian_user
      data = applicant_data.to_h.with_indifferent_access
      return unless apply_contact_strategies(data)

      data
    end

    # Public method for creating guardian/dependent relationships
    # Used by controllers when users and relationships need to be created separately
    def create_guardian_relationship(relationship_type)
      return false unless @guardian_user && @dependent_user

      create_relationship(relationship_type)
    end

    private

    def setup_guardian(guardian_id, new_guardian_attrs)
      if guardian_id.present?
        @guardian_user = User.find_by(id: guardian_id)
        return add_error?('Guardian not found') unless @guardian_user
      elsif attributes_present?(new_guardian_attrs)
        skip_email = no_email_address_flag?
        result = UserCreationService.new(
          new_guardian_attrs,
          is_managing_adult: true,
          skip_email_validation: skip_email
        ).call
        return false unless result.success?

        @guardian_user = result.data[:user]
        @guardian_temp_password = result.data[:temp_password]
      else
        return add_error?('Guardian information missing')
      end
      true
    end

    def create_dependent?(applicant_data)
      result = UserCreationService.new(applicant_data, is_managing_adult: false).call
      return false unless result.success?

      @dependent_user = result.data[:user]
      @dependent_temp_password = result.data[:temp_password]
      true
    end

    def create_relationship(relationship_type)
      return add_error?('Relationship type required') if relationship_type.blank?

      GuardianRelationship.create!(
        guardian_user: @guardian_user,
        dependent_user: @dependent_user,
        relationship_type: relationship_type
      )
      true
    rescue ActiveRecord::RecordInvalid => e
      add_error?("Failed to create relationship: #{e.message}")
      false
    end

    def apply_email_strategy(data)
      return true if params[:email_strategy].nil?

      case params[:email_strategy]
      when 'guardian'
        if @guardian_user&.email.present?
          data[:dependent_email] = @guardian_user.email
          data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
        else
          # Fallback: generate a unique email if guardian email is missing
          data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
          data[:dependent_email] = data[:email]
        end
      when 'dependent'
        # Paper passes :dependent_email; portal passes :email. Mirror the submitted contact.
        data[:email] = data[:dependent_email] if data[:email].blank? && data[:dependent_email].present?
        if data[:email].present?
          data[:dependent_email] = data[:email]
        else
          return apply_email_strategy_with('guardian', data)
        end
      else
        return apply_email_strategy_with('guardian', data)
      end

      # Final safety check: ensure email is always set
      return true if data[:email].present?

      data[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local"
      true
    end

    def apply_phone_strategy(data)
      return true if params[:phone_strategy].nil?

      case params[:phone_strategy]
      when 'guardian'
        data[:dependent_phone] = @guardian_user.phone
        phone = unique_synthetic_phone
        return false if phone.blank?

        data[:phone] = phone
      when 'dependent'
        # Paper passes :dependent_phone; portal passes :phone. Mirror the submitted contact.
        data[:phone] = data[:dependent_phone] if data[:phone].blank? && data[:dependent_phone].present?
        if data[:phone].present?
          data[:dependent_phone] = data[:phone]
        else
          return apply_phone_strategy_with('guardian', data)
        end
      else
        return apply_phone_strategy_with('guardian', data)
      end
      true
    end

    def apply_address_strategy(data)
      return if params[:address_strategy] == 'dependent'

      data[:physical_address_1] = @guardian_user.physical_address_1
      data[:physical_address_2] = @guardian_user.physical_address_2
      data[:city] = @guardian_user.city
      data[:state] = @guardian_user.state
      data[:zip_code] = @guardian_user.zip_code
    end

    def apply_email_strategy_with(strategy, data)
      @params[:email_strategy] = strategy
      apply_email_strategy(data)
    end

    def apply_phone_strategy_with(strategy, data)
      @params[:phone_strategy] = strategy
      apply_phone_strategy(data)
    end

    def unique_synthetic_phone
      SYNTHETIC_PHONE_MAX_ATTEMPTS.times do
        candidate = synthetic_phone_candidate
        return candidate unless User.exists_with_phone?(candidate)
      end

      add_error?('Unable to generate unique synthetic dependent phone')
      nil
    end

    def synthetic_phone_candidate
      value = SecureRandom.random_number(SYNTHETIC_PHONE_RANDOM_SPACE)
      digits = format('%07d', value)
      "000-#{digits[0, 3]}-#{digits[3, 4]}"
    end

    def attributes_present?(attrs)
      attrs.present? && attrs.values.any?(&:present?)
    end

    def no_email_address_flag?
      params[:guardian_no_email_address].present? && params[:guardian_no_email_address].to_s == '1'
    end

    def add_error?(message)
      @errors << message
      false
    end

    def success(data)
      Result.new(success: true, data: data)
    end

    def failure(message)
      add_error?(message)
      Result.new(success: false, message: message, data: { errors: @errors })
    end
  end
end
