# frozen_string_literal: true

module DateInputHelper
  def accessible_date_value(value)
    date = DateInputNormalizer.normalize(value)
    return value if date.blank? && value.present?
    return nil if date.blank?

    date.strftime('%m/%d/%Y')
  end
end
