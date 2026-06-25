# frozen_string_literal: true

class DateInputNormalizer
  def self.normalize(value)
    return nil if value.blank?
    return value if value.is_a?(Date)
    return value.to_date if !value.is_a?(String) && value.respond_to?(:to_date)

    string_value = value.to_s.strip
    return Date.iso8601(string_value) if string_value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    match = string_value.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z})
    return nil unless match

    Date.new(match[3].to_i, match[1].to_i, match[2].to_i)
  rescue ArgumentError
    nil
  end
end
