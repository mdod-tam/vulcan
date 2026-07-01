# frozen_string_literal: true

module Applications
  # Handles user creation and lookup for paper applications
  class UserCreationService < BaseService
    attr_reader :attrs, :is_managing_adult, :errors, :skip_user_lookup, :skip_email_validation,
                :skip_phone_validation

    def initialize(attrs, is_managing_adult: false, skip_user_lookup: false, require_disability_validation: false,
                   skip_email_validation: false, skip_phone_validation: false)
      super()
      @attrs = attrs.with_indifferent_access
      @is_managing_adult = is_managing_adult
      @skip_user_lookup = skip_user_lookup
      @require_disability_validation = require_disability_validation
      @skip_email_validation = skip_email_validation
      @skip_phone_validation = skip_phone_validation
      @errors = []
    end

    def call
      unless skip_user_lookup
        existing = find_existing_user
        if existing
          prepare_attributes
          validate_email_presence
          validate_phone_presence
          return Result.new(success: false, message: @errors.join(', '), data: { errors: @errors }) if @errors.any?

          return Result.new(
            success: true,
            data: {
              user: existing,
              email_backed_portal_created_user_id: nil,
              existing_user: true
            }
          )
        end
      end

      user = create_new_user

      if user&.persisted?
        Result.new(
          success: true,
          data: {
            user: user,
            email_backed_portal_created_user_id: email_backed_portal_created_user_id(user)
          }
        )
      else
        Result.new(success: false, message: @errors.join(', '), data: { errors: @errors })
      end
    end

    private

    def find_existing_user
      if attrs[:email].present? && !User.system_generated_email?(attrs[:email])
        user = User.find_by_email(attrs[:email])
        return user if user
      end

      # Dependents with guardian email strategy store synthetic primary email; phone lookup
      # would match unrelated users sharing the dependent's real phone.
      return if attrs[:email].present? && User.system_generated_email?(attrs[:email])

      find_by_phone if attrs[:phone].present?
    end

    def find_by_phone
      formatted_phone = User.new(phone: attrs[:phone]).phone
      User.find_by_phone(formatted_phone)
    end

    def create_new_user
      prepare_attributes
      validate_email_presence
      validate_phone_presence

      return nil if @errors.any?

      user = build_user

      if user.save
        Rails.logger.info { "Created user #{user.id} (email_backed_portal=#{user.email_backed_portal_account?})" }
        user
      else
        @errors << "Failed to create user: #{user.errors.full_messages.join(', ')}"
        nil
      end
    end

    def prepare_attributes
      normalize_contact_attrs!
      # Only auto-assign disability for paper applications, not portal (which validates)
      ensure_disability_selection unless is_managing_adult || @require_disability_validation
      attrs.delete(:notification_method)
      attrs.delete('notification_method')
    end

    def validate_email_presence
      return if skip_email_validation
      return if attrs[:email].present?

      context = is_managing_adult ? 'guardian' : 'dependent'
      @errors << "Failed to create #{context}: Email is required."
    end

    def validate_phone_presence
      return if skip_phone_validation
      return if attrs[:phone].present?

      context = is_managing_adult ? 'guardian' : 'dependent'
      @errors << "Failed to create #{context}: Phone number is required."
    end

    def build_user
      user = Users::Constituent.new(attrs)
      user.verified = true
      user.instance_variable_set(:@validate_disability_required, true) if @require_disability_validation

      if email_backed_portal_account_from_attrs?
        initial_password = SecureRandom.hex(8)
        user.password = initial_password
        user.password_confirmation = initial_password
        user.force_password_change = true
      else
        internal_password = SecureRandom.hex(32)
        user.password = internal_password
        user.password_confirmation = internal_password
        user.force_password_change = false
      end

      user
    end

    def email_backed_portal_created_user_id(user)
      user.email_backed_portal_account? ? user.id : nil
    end

    def email_backed_portal_account_from_attrs?
      User.new(email: attrs[:email], phone: attrs[:phone], phone_type: attrs[:phone_type]).email_backed_portal_account?
    end

    def normalize_contact_attrs!
      attrs[:email] = User.normalize_email(attrs[:email]) if attrs[:email].present?
      return if attrs[:phone].blank?

      normalized_phone = User.normalize_phone(attrs[:phone])
      attrs[:phone] = normalized_phone if normalized_phone.present?
    end

    def ensure_disability_selection
      disability_fields = %i[hearing_disability vision_disability speech_disability
                             mobility_disability cognition_disability]

      has_disability = disability_fields.any? { |field| ['1', true].include?(attrs[field]) }
      attrs[:hearing_disability] = '1' unless has_disability
    end
  end
end
