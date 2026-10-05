# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false

  config.eager_load = ENV['CI'].present?

  # Stale assets can invalidate Stimulus verification. Serve assets without caching.
  config.public_file_server.headers = { 'cache-control' => 'no-store' }
  config.public_file_server.enabled = true

  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Known exceptions render templates. Other exceptions propagate to the test.
  config.action_dispatch.show_exceptions = :rescuable

  config.action_controller.allow_forgery_protection = false

  config.active_storage.service = :test

  # The :test mailer stores sent mail in ActionMailer::Base.deliveries.
  config.action_mailer.delivery_method = :test

  config.action_mailer.default_url_options = { host: 'example.com' }

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.active_support.deprecation = :stderr

  config.action_controller.raise_on_missing_callback_actions = true

  config.log_level = :warn unless ENV['VERBOSE_TESTS'] == 'true'
  config.active_record.verbose_query_logs = ENV['VERBOSE_TESTS'] || false

  config.logger = ActiveSupport::Logger.new($stdout)
  if ENV['VERBOSE_TESTS']
    config.logger.level = :debug
    config.logger.formatter = config.log_formatter
  else
    config.logger.level = :warn
    config.logger.formatter = proc do |severity, _datetime, _progname, msg|
      if %w[WARN ERROR FATAL].include?(severity)
        "[#{severity}] #{msg}\n"
      else
        ''
      end
    end
  end
end
