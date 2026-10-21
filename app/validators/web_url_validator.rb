# frozen_string_literal: true

class WebUrlValidator < ActiveModel::EachValidator
  def self.safe?(value)
    return false if value.blank? || value.match?(/[[:cntrl:][:space:]]/) || value.include?('\\')

    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end

  def validate_each(record, attribute, value)
    return if self.class.safe?(value)

    record.errors.add(attribute, 'must be an absolute HTTP or HTTPS URL without credentials or spaces')
  end
end
