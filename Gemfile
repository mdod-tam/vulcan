# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.4.7'

# gem for hosting images & getting ocr functionality
gem 'aws-sdk-s3', '~> 1.197'
# use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem 'bcrypt', '~> 3.1.20'
# reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', '~> 1.18', '>= 1.18.6', require: false
# bundle and process CSS [https://github.com/rails/cssbundling-rails]
gem 'cssbundling-rails', '~> 1.4', '>= 1.4.3'
# DocuSeal API integration for digital document signing
gem 'docuseal', '~> 1.0', '>= 1.0.4'
# HTTP client for downloading files from webhooks
gem 'http', '~> 5.3', '>= 5.3.1'
# for grouping data by time periods
gem 'groupdate', '~> 6.7'
# build JSON APIs with ease [https://github.com/rails/jbuilder]
gem 'jbuilder', '~> 2.14', '>= 2.14.1'
# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem 'kamal', '~> 2.7', require: false
# pagination capability
gem 'pagy', '~> 9.4'
# use postgresql as the database for Active Record
gem 'pg', '~> 1.6', '>= 1.6.1'
# gem for sending out emails
gem 'postmark-rails', '~> 0.22.1'
# ruby pdf generation library
gem 'prawn', '~> 2.5'
# the modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem 'propshaft', '~> 1.2', '>= 1.2.1'
# use the Puma web server [https://github.com/puma/puma]
gem 'puma', '~> 6.6', '>= 6.6.1'
# rails framework
gem 'rails', '~> 8.0.3'
# gem for one-time passwords for SMS 2fa
gem 'rotp', '~> 6.3'
# gem for QR code generation for TOTP
gem 'rqrcode', '~> 3.1'
# gem for creating zip files
gem 'rubyzip', '~> 3.0.2'
# CSV processing, representing rows as Ruby hashes for easy integration with ActiveRecord
gem 'smarter_csv', '~> 1.14', '>= 1.14.4'
# hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails', '~> 1.3', '>= 1.3.4'
# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem 'thruster', '~> 0.1.15', require: false
# hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails', '~> 2.0', '>= 2.0.16'
# for fax capabilities
gem 'twilio-ruby', '~> 7.7', '>= 7.7.1'
# windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', '~> 1.2025', '>= 1.2025.2'
# gem for 2fa
gem 'webauthn', '~> 3.4', '>= 3.4.1'

# use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem 'solid_cable', '~> 3.0', '>= 3.0.12'
gem 'solid_cache', '~> 1.0', '>= 1.0.7'
gem 'solid_queue', '~> 1.2', '>= 1.2.1'

# bundle and transpile JavaScript [https://github.com/rails/jsbundling-rails]
gem 'jsbundling-rails'

group :development, :test do
  gem 'brakeman', '~> 7.1', require: false
  gem 'byebug', '~> 12.0'
  gem 'debug', '~> 1.11', require: 'debug/prelude'
end

group :development do
  gem 'bullet'
  gem 'debride'
  gem 'erb_lint'
  gem 'letter_opener'
  gem 'rubocop'
  gem 'rubocop-capybara'
  gem 'rubocop-factory_bot'
  gem 'rubocop-rails'
  gem 'web-console'
end

group :test do
  gem 'capybara', '~> 3.40'
  gem 'cuprite', '~> 0.17'
  gem 'database_cleaner-active_record'
  gem 'factory_bot_rails'
  gem 'minitest-rails', '~> 8.0.0'
  gem 'mocha', require: false
  gem 'rails-controller-testing'
  gem 'selenium-webdriver'
end
