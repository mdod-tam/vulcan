# frozen_string_literal: true

module Icanconnect
  module Funding
    class Ineligible < ArgumentError; end

    def self.validate!(application, source:, on: Date.current)
      raise Ineligible, 'Choose MAT or iCanConnect funding.' unless Icanconnect::FUNDING_SOURCES.include?(source)
      return if source == 'mat'

      unless application.icanconnect_eligible?(on: on)
        raise Ineligible, 'iCanConnect costs need an approved DeafBlind application with approved disability and income proof.'
      end
      return unless application.icanconnect_income_review_due?(on: on)

      raise Ineligible, 'Request updated income proof from the application before adding new iCanConnect equipment or services. MAT funding is still available.'
    end
  end
end
