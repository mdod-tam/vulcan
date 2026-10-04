# frozen_string_literal: true

# Puma configuration DSL: https://puma.io/puma/Puma/DSL.html.
# With no WEB_CONCURRENCY, development and test use single mode. Other environments use two workers.
# RAILS_MAX_THREADS defaults to five.
# Provide at least as many connections in each resource pool as threads per worker.
app_env = ENV.fetch('RAILS_ENV') { ENV.fetch('RACK_ENV', 'development') }
worker_count = Integer(ENV['WEB_CONCURRENCY'] || (%w[development test].include?(app_env) ? 0 : 2))
workers worker_count
threads_count = Integer(ENV['RAILS_MAX_THREADS'] || 5)
threads threads_count, threads_count

preload_app!

# Bind to the IPv6 wildcard address.
port(ENV['PORT'] || 3000, '::')

persistent_timeout(95)

rackup      DefaultRackup if defined?(DefaultRackup)

environment app_env

# Each worker needs a database connection after the fork.
# The worker hook requires cluster mode.
if worker_count.positive?
  before_worker_boot do
    ActiveRecord::Base.establish_connection if defined?(ActiveRecord)
  end
end

# SOLID_QUEUE_IN_PUMA enables the supervisor inside Puma.
plugin :solid_queue if ENV['SOLID_QUEUE_IN_PUMA']
