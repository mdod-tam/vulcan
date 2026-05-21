# frozen_string_literal: true

require 'uri'

WebAuthn.configure do |config|
  # Relying Party name
  config.rp_name = 'MAT Vulcan'

  application_host = ENV['APPLICATION_HOST'].to_s.strip.sub(%r{\Ahttps?://}, '').split('/').first

  # Allowed origins (URLs where the app is accessed)
  allowed_origins = ENV['WEBAUTHN_ORIGIN'].to_s.split(',').map(&:strip).compact_blank
  allowed_origins << "https://#{application_host}" if allowed_origins.empty? && Rails.env.production? && application_host.present?
  allowed_origins << 'http://localhost:3000' if Rails.env.development?
  config.allowed_origins = allowed_origins.compact.uniq

  # Relying Party ID - explicitly set for localhost development
  if Rails.env.development?
    config.rp_id = 'localhost'
  elsif ENV['WEBAUTHN_RP_ID'].present?
    config.rp_id = ENV['WEBAUTHN_RP_ID'].strip
  elsif config.allowed_origins.one?
    config.rp_id = URI.parse(config.allowed_origins.first).host
  end

  # Optional: Configure timeout for credential creation/authentication
  config.credential_options_timeout = 120_000 # Milliseconds
end
