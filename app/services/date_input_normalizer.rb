# frozen_string_literal: true

# The one interpretation of a typed date. Month comes first in every locale, so a Spanish page
# never changes what a date means.
#
# Accepted forms (the year always has four digits):
#   9/9/2026, 09/09/2026, 09-09-2026, 09.09.2026, 09 09 2026  month, day, year; one separator kind
#   09092026                                                   MMDDYYYY
#   2026-09-09                                                 ISO, as stored and as sent by native inputs
#
# Anything else is nil, including impossible dates and two-digit years. Do not fall back to
# Date.parse: it reads 09/10/2026 as October 9 and 9/9/26 as 2009-09-26.
class DateInputNormalizer
  FORMATS = [
    /\A(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})\z/,
    %r{\A(?<month>\d{1,2})(?<sep>[/.\- ])(?<day>\d{1,2})\k<sep>(?<year>\d{4})\z},
    /\A(?<month>\d{2})(?<day>\d{2})(?<year>\d{4})\z/
  ].freeze

  def self.normalize(value)
    return nil if value.blank?
    return value if value.is_a?(Date)
    return value.to_date if !value.is_a?(String) && value.respond_to?(:to_date)

    string_value = value.to_s.strip.gsub(/\s+/, ' ')
    match = FORMATS.lazy.filter_map { |format| string_value.match(format) }.first
    return nil unless match

    Date.new(match[:year].to_i, match[:month].to_i, match[:day].to_i)
  rescue ArgumentError
    nil
  end

  # Submitted but unreadable. Blank is not invalid; presence is a separate rule.
  def self.invalid?(value)
    value.present? && normalize(value).nil?
  end
end
