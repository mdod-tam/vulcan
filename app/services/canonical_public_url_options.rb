# frozen_string_literal: true

class CanonicalPublicUrlOptions
  def self.call
    new.call
  end

  def call
    mailer_options = (Rails.application.config.action_mailer.default_url_options || {}).to_h.symbolize_keys
    route_options = Rails.application.routes.default_url_options.to_h.symbolize_keys
    host = mailer_options[:host].presence || route_options[:host].presence
    protocol = mailer_options[:protocol].presence || route_options[:protocol].presence ||
               (Rails.env.production? ? 'https' : 'http')

    validate!(host, protocol)

    {
      host: host,
      port: mailer_options[:port] || route_options[:port],
      protocol: protocol
    }.compact
  end

  private

  def validate!(host, protocol)
    return unless Rails.env.production?

    raise ArgumentError, 'Canonical public URL host is not configured' if host.blank? || host == 'example.com'
    raise ArgumentError, 'Canonical public URLs must use HTTPS in production' unless protocol == 'https'
  end
end
