# frozen_string_literal: true

module Vouchers
  class ValueCalculator
    attr_reader :constituent

    def initialize(constituent)
      @constituent = constituent
    end

    def calculate
      total_value = 0

      Users::Constituent::DISABILITY_TYPES.each do |disability_type|
        next unless constituent.send("#{disability_type}_disability")

        value = Policy.voucher_value_for_disability(disability_type)
        Rails.logger.info "Adding #{value} for #{disability_type} disability"
        total_value += value
      end

      Rails.logger.info "Final voucher value calculated: #{total_value}"
      total_value
    end

    def self.calculate_for(constituent)
      new(constituent).calculate
    end

    private

    def log_calculation(disability_type, value)
      Rails.logger.debug do
        "Voucher calculation: #{disability_type} disability " \
          "present: #{constituent.send("#{disability_type}_disability")}, " \
          "value: #{value}"
      end
    end
  end
end
