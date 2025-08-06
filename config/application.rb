# frozen_string_literal: true

require_relative 'boot'
require 'rails/all'

# Fix for Rails 8.0.2 compatibility issue
require 'action_dispatch/routing/url_for'

# Require the gems listed in Gemfile
Bundler.require(*Rails.groups)

# define the MatVulcan
module MatVulcan
  # define the Application class
  class Application < Rails::Application
    # Shared host configuration for URL generation
    PRODUCTION_HOST = 'morning-dawn-84330-f594822dd77d.herokuapp.com'

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0
    config.time_zone = 'Eastern Time (US & Canada)'
    config.active_record.default_timezone = :utc

    config.action_mailer.delivery_method = :postmark
    config.action_mailer.postmark_settings = {
      api_token: Rails.application.credentials.postmark_api_token
    }
    config.action_mailer.default_url_options = { host: PRODUCTION_HOST }

    # Factory_bot configuration
    config.generators do |g|
      g.factory_bot dir: 'test/factories'
      g.factory_bot suffix: false
      g.test_framework :minitest
      g.fixture_replacement :factory_bot, dir: 'test/factories'
    end

    # Flash message configuration
    # Options: :toast (JavaScript notifications), :traditional (Rails HTML), :both
    # Default: :toast for normal environments, :both for test environment
    config.flash_mode = :traditional  # Use traditional Rails flash messages
  end
end
