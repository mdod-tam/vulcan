# frozen_string_literal: true

module Notifications
  # Service for normalizing constituent and notification parameters
  # Handles both hash and object inputs consistently
  class ParameterNormalizationService < BaseService
    def self.call(constituent_params, notification_params)
      new(constituent_params, notification_params).call
    end

    def initialize(constituent_params, notification_params)
      super()
      @constituent_params = constituent_params
      @notification_params = notification_params
    end

    def call
      normalized_data = {
        constituent: normalize_constituent,
        notification: normalize_notification
      }

      success('Parameters normalized successfully', normalized_data)
    rescue StandardError => e
      log_error(e, 'Failed to normalize parameters')
      failure("Unable to normalize parameters: #{e.message}")
    end

    private

    def normalize_constituent
      {
        id: extract_value(@constituent_params, :id),
        first_name: extract_value(@constituent_params, :first_name),
        last_name: extract_value(@constituent_params, :last_name),
        email: extract_value(@constituent_params, :email),
        communication_preference: extract_value(@constituent_params, :communication_preference),
        locale: extract_value(@constituent_params, :locale),
        is_object: !@constituent_params.is_a?(Hash)
      }
    end

    def normalize_notification
      {
        household_size: extract_value(@notification_params, :household_size).to_i,
        annual_income: extract_value(@notification_params, :annual_income),
        additional_notes: extract_value(@notification_params, :additional_notes)
      }
    end

    def extract_value(source, key)
      if source.is_a?(Hash)
        source[key] || source[key.to_s]
      else
        source.public_send(key)
      end
    rescue NoMethodError
      nil
    end
  end
end
