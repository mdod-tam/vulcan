# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
Rails.application.eager_load!
require 'rails/test_help'

# Suppress info and debug logs unless VERBOSE_TESTS is set.
Rails.logger.level = :warn unless ENV['VERBOSE_TESTS']
ActiveRecord::Base.logger.level = :warn unless ENV['VERBOSE_TESTS']

ActiveStorage.logger.level = :error if defined?(ActiveStorage.logger)

Rails.application.config.active_record.verbose_query_logs = false unless ENV['VERBOSE_TESTS']

# Truncate the database before seeds load.
begin
  require 'database_cleaner/active_record'
  DatabaseCleaner.clean_with(:truncation)
rescue LoadError
  warn "DatabaseCleaner not found. Add `gem 'database_cleaner-active_record', group: :test`."
end

# Seed the parent once. Forked worker databases load the same baseline below.
require_relative 'support/document_scan_helper'
unless defined?(SEEDS_LOADED)
  Rails.application.load_seed
  SEEDS_LOADED = true
end

# Core test libraries
require 'minitest/mock'
require 'mocha/minitest'
require 'capybara/rails'

Capybara.default_max_wait_time = 5

# Support helpers
Rails.root.glob('test/support/**/*.rb').each { |f| require f }

require 'webauthn/fake_client'

# Test-only controllers & routes
require_relative 'controllers/webhooks/test_base_controller'

# Generator test-case destination root
require_relative 'lib/generators/test_case_config'
TestCaseConfig.configure_generator_test_case(Rails::Generators::TestCase)

# Integration requests share browser metadata and route normalization.
module DefaultHeadersRequestPatch
  %i[get post put patch delete].each do |method|
    define_method(method) do |path, **args|
      normalized_path = normalize_request_path(path, args)
      super(normalized_path, **merge_default_headers(args))
    end
  end

  private

  def merge_default_headers(args)
    return args unless respond_to?(:default_headers, true)

    incoming_headers = (args[:headers] || {}).transform_keys(&:to_s)
    args[:headers] = default_headers.merge(incoming_headers)
    args
  end

  def normalize_request_path(path, args)
    return path unless path.is_a?(Symbol)

    controller_path = inferred_controller_path
    route_id = args.dig(:params, :id)
    return path if controller_path.blank?

    Rails.application.routes.url_helpers.url_for(
      only_path: true,
      controller: controller_path,
      action: path,
      id: route_id
    )
  rescue StandardError
    path
  end

  def inferred_controller_path
    test_class_name = self.class.name.to_s
    return if test_class_name.blank?

    test_class_name.sub(/Test\z/, '').underscore
                   .sub(%r{\A/}, '')
                   .sub('_controller', '')
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) { prepend DefaultHeadersRequestPatch }

# ActiveSupport::TestCase – global helpers & teardown
module ActiveSupport
  class TestCase
    include FactoryBot::Syntax::Methods
    include VoucherTestHelper
    include ActionMailer::TestHelper
    include MailerTestHelper
    include AuthenticationTestHelper
    include FlashTestHelper
    include FormTestHelper
    include ActiveStorageHelper
    include AttachmentTestHelper
    include ProofTestHelper
    include FplPolicyHelpers
    include PaperApplicationContextHelpers

    attr_reader :product

    # Parallel tests are off: the pg gem segfaults on Ruby 3.4.5-3.4.7 (possibly an ARM build issue).
    # To re-enable, use parallelize(workers: ENV.fetch('PARALLEL_WORKERS', :number_of_processors), with: :processes).
    parallelize(workers: 1)

    if defined?(DatabaseCleaner)
      parallelize_setup do |_worker|
        DatabaseCleaner.clean_with(:truncation)
        Rails.application.load_seed
      end

      setup do
        DatabaseCleaner.strategy = :transaction
        DatabaseCleaner.start
        # Provide the default flag for stamp_workflow_defaults! and scrub_income_fields.
        FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = false }
        # Email is on unless a test turns it off through EmailDelivery::ControlWriter.
        EmailDelivery::CONTROL_NAMES.each { |name| FeatureFlag.find_or_create_by!(name: name) { |f| f.enabled = true } }
      end

      teardown { DatabaseCleaner.clean }
    end

    # Skip MIME identification to reduce work for test blobs.
    def create_lightweight_blob(filename: 'test.pdf', content_type: 'application/pdf', content: 'stub')
      ActiveStorage::Blob.create_after_upload!(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type,
        identify: false
      )
    end

    # Remove authentication and paper context between tests.
    teardown do
      Current.reset if defined?(Current)

      Thread.current[:paper_application_context] = nil

      @issued_test_session = nil
    end

    # Misc. helper assertions / utilities
    def assert_enqueued_email_with(mailer_class, method_name, mailer_args: nil, &)
      base_job_args = [mailer_class.to_s, method_name.to_s, 'deliver_now']

      matcher = if mailer_args.nil?
                  ->(*actual) { actual[0, 3] == base_job_args }
                else
                  expected = base_job_args + Array(mailer_args)
                  ->(*actual) { actual == expected }
                end

      assert_enqueued_with(job: EmailDelivery::MailDeliveryJob, args: matcher, &)
    end

    def assert_test_has_assertions
      assert_operator assertions, :>=, 1, 'Test is missing assertions'
    end

    def default_headers
      {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }
    end

    if ENV['VERBOSE_TESTS']
      test 'ensure test_auth_status route is recognised' do
        if Rails.application.routes.url_helpers.respond_to?(:test_auth_status_path)
          assert_equal '/test/auth_status',
                       Rails.application.routes.url_helpers.test_auth_status_path
        else
          assert true, 'Route unavailable in this environment – skipping assertion'
        end
      end
    end

    # url_for needs a host for ActiveStorage URLs.
    setup { ActiveStorage::Current.url_options = { host: 'localhost:3000' } }
  end
end

# Rails-provided test adapters
ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.deliveries = []

ActiveJob::Base.queue_adapter = :test
Rails.application.config.active_storage.service = :test
