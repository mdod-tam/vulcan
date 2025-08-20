# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.4.5'

# gem for hosting images & getting ocr functionality
gem 'aws-sdk-s3'
# for fax capabilities
gem 'twilio-ruby', '~> 7.5.1'
# use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem 'bcrypt', '~> 3.1.20'
# reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', require: false
# bundle and process CSS [https://github.com/rails/cssbundling-rails]
gem 'cssbundling-rails'
# build JSON APIs with ease [https://github.com/rails/jbuilder]
gem 'jbuilder'
# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem 'kamal', require: false
# use postgresql as the database for Active Record
gem 'pg', '~> 1.6', '>= 1.6.1'
# gem for sending out emails
gem 'postmark-rails', '~> 0.22.1'
# the modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem 'propshaft'
# use the Puma web server [https://github.com/puma/puma]
gem 'puma', '>= 6.6.0'
# rails framework
gem 'rails', '~> 8.0.2'
# gem for one-time passwords for SMS 2fa
gem 'rotp'
# gem for QR code generation for TOTP
gem 'rqrcode'
# gem for creating zip files
gem 'rubyzip', '3.0.0.rc2'
# hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails'
# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem 'thruster', require: false
# hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails'
# pagination capability
gem 'pagy'
# for grouping data by time periods
gem 'groupdate'
# ruby pdf generation library
gem 'prawn', '~> 2.5'
# pdf extraction, display, etc capability
gem 'mupdf', '~> 1.0'
# CSV processing, representing rows as Ruby hashes for easy integration with ActiveRecord
gem 'smarter_csv'
# windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data'
# gem for 2fa
gem 'webauthn', '~> 3.4'

# use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem 'solid_cable'
gem 'solid_cache'
gem 'solid_queue'

# bundle and transpile JavaScript [https://github.com/rails/jsbundling-rails]
gem 'jsbundling-rails'

group :development, :test do
  gem 'brakeman', '~> 7.0', require: false
  gem 'byebug'
  gem 'debug', require: 'debug/prelude'
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
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
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem 'capybara'
  gem 'cuprite'
  gem 'database_cleaner-active_record'
  gem 'factory_bot_rails'
  gem 'minitest-rails', '~> 8.0.0'
  gem 'mocha', require: false
  gem 'rails-controller-testing'
  gem 'selenium-webdriver'
end
