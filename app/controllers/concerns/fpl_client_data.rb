# frozen_string_literal: true

# Renders the FPL thresholds into the form's data attributes so client validation needs no configuration request.
module FplClientData
  extend ActiveSupport::Concern

  included do
    helper_method :fpl_thresholds_json, :fpl_modifier_value
  end

  private

  def fpl_thresholds_json
    fpl_client_data[:thresholds].to_json
  end

  def fpl_modifier_value
    fpl_client_data[:modifier]
  end

  def fpl_client_data
    @fpl_client_data ||= IncomeThresholdCalculationService.client_data
  end
end
