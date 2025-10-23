# frozen_string_literal: true

module Applications
  # Handles user creation and lookup for paper applications
  class UserCreationService < BaseService
    attr_reader :attrs, :is_managing_adult, :errors, :skip_user_lookup

    def initialize(attrs, is_managing_adult: false, skip_user_lookup: false, require_disability_validation: false)
      super()
      @attrs = attrs.with_indifferent_access
      @is_managing_adult = is_managing_adult
      @skip_user_lookup = skip_user_lookup
      @require_disability_validation = require_disability_validation
      @errors = []
    end

    def call
      user = skip_user_lookup ? create_new_user : (find_existing_user || create_new_user)

      if user&.persisted?
        Result.new(success: true, data: { user: user, temp_password: @temp_password })
      else
        Result.new(success: false, message: @errors.join(', '), data: { errors: @errors })
      end
    end

    private

    def find_existing_user
      return nil unless attrs[:email].present? && attrs[:email].exclude?('@system.matvulcan.local')

      user = User.find_by_email(attrs[:email])
      user ||= find_by_phone if attrs[:phone].present?
      user
    end

    def find_by_phone
      formatted_phone = User.new(phone: attrs[:phone]).phone
      User.find_by_phone(formatted_phone)
    end

    def create_new_user
      prepare_attributes
      validate_email_presence

      return nil if @errors.any?

      user = build_user

      if user.save
        Rails.logger.info { "Created user #{user.id} with email #{user.email}" }
        user
      else
        @errors << "Failed to create user: #{user.errors.full_messages.join(', ')}"
        nil
      end
    end

    def prepare_attributes
      # Only auto-assign disability for paper applications, not portal (which validates)
      ensure_disability_selection unless is_managing_adult || @require_disability_validation
      attrs.delete(:notification_method)
      attrs.delete('notification_method')
    end

    def validate_email_presence
      return if attrs[:email].present?

      context = is_managing_adult ? 'guardian' : 'dependent'
      @errors << "Failed to create #{context}: Email is required."
    end

    def build_user
      @temp_password = SecureRandom.hex(8)

      Users::Constituent.new(attrs).tap do |user|
        user.password = @temp_password
        user.password_confirmation = @temp_password
        user.verified = true
        user.force_password_change = true
        user.instance_variable_set(:@validate_disability_required, true) if @require_disability_validation
      end
    end

    def ensure_disability_selection
      disability_fields = %i[hearing_disability vision_disability speech_disability
                             mobility_disability cognition_disability]

      has_disability = disability_fields.any? { |field| ['1', true].include?(attrs[field]) }
      attrs[:hearing_disability] = '1' unless has_disability
    end
  end
end
