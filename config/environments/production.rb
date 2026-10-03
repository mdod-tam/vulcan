# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings here take precedence over config/application.rb.

  config.enable_reloading = false

  # Rake tasks ignore eager_load.
  config.eager_load = true

  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true

  # All assets have digest stamps, so a far-future expiry is safe.
  config.public_file_server.headers = { 'cache-control' => "public, max-age=#{1.year.to_i}" }

  # Serve images, stylesheets, and JavaScript from an asset server.
  # config.asset_host = "http://assets.example.com"

  # esbuild bundles Turbo and Stimulus, so their duplicate gem assets are excluded.
  config.assets.excluded_paths += [
    Turbo::Engine.root.join('app/assets/javascripts'),
    Stimulus::Engine.root.join('app/assets/javascripts')
  ]

  # S3 or Bucketeer credentials come from config/storage.yml.
  config.active_storage.service = :s3

  # An SSL-terminating reverse proxy receives all requests.
  config.assume_ssl = true

  # Also turns on Strict-Transport-Security and secure cookies.
  config.force_ssl = true

  # Do not redirect the /up health check to HTTPS.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  config.log_tags = [:request_id]
  config.logger   = ActiveSupport::TaggedLogging.logger($stdout)

  # The "debug" level can log personally identifiable information.
  config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info')

  config.silence_healthcheck_path = '/up'

  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Uncomment to ignore email delivery errors. The Rails default raises them.
  # config.action_mailer.raise_delivery_errors = false

  # Host for mailer links, for example "myapp.herokuapp.com".
  # The default lets assets compile at build time. Runtime needs a real APPLICATION_HOST.
  config.action_mailer.default_url_options = { host: ENV.fetch('APPLICATION_HOST', 'example.com'), protocol: 'https' }

  # A missing translation falls back to I18n.default_locale.
  config.i18n.fallbacks = true

  config.active_record.dump_schema_after_migration = false

  config.active_record.attributes_for_inspect = [:id]

  # Protect against DNS rebinding and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip host authorization for the /up health check.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
