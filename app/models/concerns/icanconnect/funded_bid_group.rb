# frozen_string_literal: true

module Icanconnect
  module FundedBidGroup
    extend ActiveSupport::Concern

    included do
      validates :funding_source, inclusion: { in: Icanconnect::FUNDING_SOURCES }
      validate :bid_funding_retained
    end

    private

    def bid_funding_retained
      errors.add(:funding_source, 'cannot change after bid assignment') if persisted? && will_save_change_to_funding_source?
      errors.add(:funding_source, 'ICC shelf stock is outside this workflow') if funding_source == 'icanconnect' && purpose.to_s == 'program_stock'
    end
  end
end
