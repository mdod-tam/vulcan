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
  warn "⚠️  DatabaseCleaner not found.  Add `gem 'database_cleaner-active_record', group: :test`."
end

# SEEDS_LOADED guards seed loading within this process.
unless defined?(SEEDS_LOADED)
  if Rails.env.test?
    # Resolve Invoice before the code changes its callbacks.
    Invoice.name

    # Seeds do not need payment email or updates to related invoice records.
    # Suppress :send_payment_notification during seed loading.
    # If the callback changes or disappears, log the problem and let seed loading continue.
    begin
      Invoice.skip_callback(:save, :after, :send_payment_notification)
    rescue ArgumentError => e
      Rails.logger.warn "Could not skip :send_payment_notification callback on Invoice: #{e.message}"
    end
  end
  Rails.application.load_seed
  # Restore the callback so tests exercise the real payment notice.
  Invoice.set_callback(:save, :after, :send_payment_notification, if: :payment_details_added?) if Rails.env.test?
  SEEDS_LOADED = true
end

# Parallel workers restore shared text headers and footers after truncation.
def load_critical_email_templates
  EmailTemplate.find_or_create_by!(name: 'email_header_text', format: :text) do |template|
    template.subject = 'Email Header Text'
    template.description = 'Standard text header used in all email templates'
    template.body = <<~TEXT
      <%= title %>

      <% if defined?(subtitle) && subtitle.present? %>
      <%= subtitle %>
      <% end %>
    TEXT
    template.version = 1
  end

  EmailTemplate.find_or_create_by!(name: 'email_footer_text', format: :text) do |template|
    template.subject = 'Email Footer Text'
    template.description = 'Standard text footer used in all email templates'
    template.body = <<~TEXT
      --
      <%= organization_name %>
      Email: <%= contact_email %>
      Website: <%= website_url %>

      <% if defined?(show_automated_message) && show_automated_message %>
      This is an automated message. Please do not reply directly to this email.
      <% end %>
    TEXT
    template.version = 1
  end
rescue StandardError => e
  # Template creation failures produce a warning and do not abort the worker.
  Rails.logger.warn "Failed to create critical email templates: #{e.message}"
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

# Integration requests use default headers and restore Current.user afterward.
module DefaultHeadersRequestPatch
  %i[get post put patch delete].each do |method|
    define_method(method) do |path, **args|
      normalized_path = normalize_request_path(path, args)
      result = super(normalized_path, **merge_default_headers(args))

      # Authentication assertions use Current.user after the request.
      restore_current_user_after_request

      result
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

  def restore_current_user_after_request
    # An explicit helper user takes precedence over other sources.
    if defined?(@authenticated_user) && @authenticated_user.present?
      Current.user = @authenticated_user if defined?(Current)
      return
    end

    if defined?(Current.test_user_id) && Current.test_user_id.present?
      test_user = User.find_by(id: Current.test_user_id)
      Current.user = test_user if test_user && defined?(Current)
      return
    end

    # The fallback uses a recent Session instead of cookie decryption.
    return unless defined?(Session) && defined?(User)

    recent_session = Session.includes(:user)
                            .where('created_at > ?', 5.seconds.ago)
                            .order(created_at: :desc)
                            .first

    return if recent_session&.user.blank?

    @authenticated_user = recent_session.user
    Current.user = @authenticated_user if defined?(Current)
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

    # Disable parallel tests due to pg gem segfault with Ruby 3.4.5-3.4.7 (maybe due to ARM compilation issue?)
    # TODO: Re-enable after addressing segfault by restoring:
    # system_test_workers = ENV.fetch('SYSTEM_TEST_WORKERS', 4).to_i
    # parallel_workers = ENV.fetch('PARALLEL_WORKERS', :number_of_processors)
    # parallelize(workers: parallel_workers, with: :processes)
    parallelize(workers: 1)

    if defined?(DatabaseCleaner)
      parallelize_setup do |_worker|
        DatabaseCleaner.clean_with(:truncation)
        load_critical_email_templates
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
      Current.test_user_id = nil if defined?(Current)

      Thread.current[:paper_application_context] = nil

      @authenticated_user = nil
      @test_user_id = nil
      @session_token = nil

      ENV['TEST_USER_ID'] = nil if ENV['TEST_USER_ID'].present?
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
      base = {
        'HTTP_USER_AGENT' => 'Rails Testing',
        'REMOTE_ADDR' => '127.0.0.1'
      }
      # Do not set a raw Cookie header here.
      # It replaces the cookie jar and removes the Rails session cookie, including skip_2fa.
      # X-Test-User-Id restores test authentication. Sign-in helpers set session_token in the cookie jar.
      base['X-Test-User-Id'] = @test_user_id.to_s if defined?(@test_user_id) && @test_user_id.present?

      base
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

Application.skip_wait_period_validation = true
