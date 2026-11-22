# frozen_string_literal: true

class MileageRate < ApplicationRecord
  include TypedDateInput

  typed_date_input :effective_on

  validates :effective_on, presence: true, uniqueness: true
  validates :dollars_per_mile, presence: true
  validate :rate_has_thousandths_precision

  def self.parse(value)
    value = value.to_s('F') if value.is_a?(BigDecimal)
    text = value.to_s.strip
    return unless text.match?(/\A\d+(?:\.\d{1,3})?\z/)

    amount = BigDecimal(text)
    amount if amount <= BigDecimal('999.999')
  end

  def self.for_service_date(date)
    date = DateInputNormalizer.normalize(date)
    return unless date

    where(effective_on: ..date).order(effective_on: :desc).pick(:dollars_per_mile)
  end

  private

  def rate_has_thousandths_precision
    return if dollars_per_mile_before_type_cast.blank? || self.class.parse(dollars_per_mile_before_type_cast)

    errors.add(:dollars_per_mile, 'must be between 0 and 999.999, with no more than three decimal places')
  end
end
