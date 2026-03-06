# frozen_string_literal: true

module Notifications
  # Main service for handling income threshold exceeded notifications
  # Coordinates parameter normalization and threshold calculation
  # Returns prepared data for the mailer to render
  class IncomeThresholdService < BaseService
    def self.call(constituent_params, notification_params)
      new(constituent_params, notification_params).call
    end

    def initialize(constituent_params, notification_params)
      super()
      @constituent_params = constituent_params
      @notification_params = notification_params
    end

    def call
      normalize_parameters
      calculate_threshold

      success('Income threshold notification data prepared successfully', {
                constituent: @constituent,
                notification: @notification,
                threshold_data: @threshold_data,
                threshold: @threshold
              })
    rescue StandardError => e
      log_error(e, 'Failed to prepare income threshold notification data')
      failure("Unable to prepare notification data: #{e.message}")
    end

    private

    def normalize_parameters
      result = ParameterNormalizationService.call(@constituent_params, @notification_params)
      return add_error('Parameter normalization failed') unless result.success?

      @constituent = result.data[:constituent]
      @notification = result.data[:notification]
    end

    def calculate_threshold
      result = IncomeThresholdCalculationService.call(@notification[:household_size])
      return add_error('Threshold calculation failed') unless result.success?

      @threshold_data = result.data
      @threshold = @threshold_data[:threshold]
    end
  end
end
