# frozen_string_literal: true

require_relative 'boot'
require 'rails/all'

# Load routing helpers before the bundled gems.
require 'action_dispatch/routing/url_for'

# Require the gems listed in Gemfile
Bundler.require(*Rails.groups)

module MatVulcan
  class Application < Rails::Application
    config.load_defaults 8.0
    config.time_zone = 'Eastern Time (US & Canada)'
    config.active_record.default_timezone = :utc

    # Postmark mailer configuration (host URLs set per-environment)
    config.action_mailer.delivery_method = :postmark
    config.action_mailer.postmark_settings = {
      api_token: Rails.application.credentials.postmark_api_token
    }

    # Factory_bot configuration
    config.generators do |g|
      g.factory_bot dir: 'test/factories'
      g.factory_bot suffix: false
      g.test_framework :minitest
      g.fixture_replacement :factory_bot, dir: 'test/factories'
    end

    # Flash message configuration: use traditional Rails flash only
    config.flash_mode = :traditional
  end
end
