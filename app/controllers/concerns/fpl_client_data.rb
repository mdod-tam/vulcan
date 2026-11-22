# frozen_string_literal: true

# Renders the FPL thresholds into the form's data attributes so client validation needs no configuration request.
module FplClientData
  extend ActiveSupport::Concern

  included do
    helper_method :income_validation_data
  end

  private

  def income_validation_data(locale: I18n.locale)
    {
      'income-validation-fpl-thresholds-value' => fpl_client_data[:thresholds].to_json,
      'income-validation-modifier-value' => fpl_client_data[:modifier],
      'income-validation-additional-person-value' => fpl_client_data[:additional_person],
      'income-validation-messages-value' => I18n.t('applications.income_validation', locale: locale).to_json,
      'income-validation-locale-value' => locale
    }
  end

  def fpl_client_data
    @fpl_client_data ||= IncomeThresholdCalculationService.client_data
  end
end
