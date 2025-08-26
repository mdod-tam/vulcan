# frozen_string_literal: true

# The test environment is used exclusively to run your application's test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb. While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # recommend that you enable it in continuous integration systems to ensure eager loading is working properly before deploying your code.
  config.eager_load = ENV['CI'].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { 'cache-control' => 'public, max-age=3600' }
  config.public_file_server.enabled = true

  # Enable serving of assets in test environment (Propshaft configuration)
  # Propshaft doesn't use the same config.assets.* settings as Sprockets
  # Instead, ensure assets are served from the public directory
  config.public_file_server.enabled = true

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # The :test delivery method accumulates sent emails in the ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: 'example.com' }

  # Configure Solid Queue for testing
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Reduce log noise in tests - only show warnings/errors unless verbose mode requested
  config.log_level = :warn unless ENV['VERBOSE_TESTS'] == 'true'
  config.active_record.verbose_query_logs = ENV['VERBOSE_TESTS'] || false

  # Configure logger output
  config.logger = ActiveSupport::Logger.new($stdout)
  if ENV['VERBOSE_TESTS']
    # Detailed logging for debugging
    config.logger.level = :debug
    config.logger.formatter = config.log_formatter
  else
    # Minimal logging for faster test runs
    config.logger.level = :warn
    config.logger.formatter = proc do |severity, _datetime, _progname, msg|
      # Only show the essential info for warnings/errors
      if %w[WARN ERROR FATAL].include?(severity)
        "[#{severity}] #{msg}\n"
      else
        ''
      end
    end
  end
end
