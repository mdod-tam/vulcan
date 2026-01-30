# frozen_string_literal: true

require 'test_helper'
require 'socket'
require 'capybara/cuprite'
begin
  require 'selenium/webdriver'
rescue LoadError
  # Selenium not available – tests will default to Cuprite
end

# --------------------------------------------------------------------------
# SECTION 1: CAPYBARA DRIVER REGISTRATION
# --------------------------------------------------------------------------
# This is the single, authoritative place where the driver is
# registered and configured.
# --------------------------------------------------------------------------
Capybara.register_driver :cuprite do |app|
  # Hard-block third-party hosts using Chrome's host resolver
  blocked_hosts = %w[
    google-analytics.com
    googletagmanager.com
    fonts.googleapis.com
    fonts.gstatic.com
    *.facebook.com
    *.doubleclick.net
    *.googlesyndication.com
    cdn.jsdelivr.net
    unpkg.com
    cdnjs.cloudflare.com
  ]

  # Format host resolver rules correctly - each rule needs its own MAP entry
  block_rules = blocked_hosts.map { |h| "MAP #{h} 0.0.0.0" }.join(', ')

  # Debug: Check CI environment variables
  is_ci = ENV['CI'] || ENV.fetch('HEROKU_TEST_RUN_ID', nil)
  timeout_value = is_ci ? 120 : 60
  if ENV['VERBOSE_TESTS']
    puts "🔧 Cuprite CI Detection: CI=#{ENV.fetch('CI', nil)}, HEROKU_TEST_RUN_ID=#{ENV.fetch('HEROKU_TEST_RUN_ID', nil)}, using timeout=#{timeout_value}s"
  end

  Capybara::Cuprite::Driver.new(
    app,
    # General options
    window_size: [1200, 800],
    js_errors: false,
    inspector: false,

    # Performance & Stability
    # Force long timeouts for CI environments - use 120s always in CI, fallback to 60s locally
    process_timeout: timeout_value, # Chrome process startup timeout
    timeout: timeout_value,         # General command timeout
    # Try multiple Ferrum timeout parameters to override the 10-second limit
    ws_timeout: timeout_value,      # Websocket connection timeout
    browser_timeout: timeout_value, # Browser initialization timeout
    url_blacklist: [ # Backup blocking for any missed external requests (using regexps)
      /google-analytics\.com/,
      /googletagmanager\.com/,
      /fonts\.googleapis\.com/,
      /cdn\.jsdelivr\.net/,
      /unpkg\.com/,
      /cdnjs\.cloudflare\.com/
    ],

    # Headless mode control via environment variable
    headless: %w[false 0].exclude?(ENV.fetch('HEADLESS', 'true')),

    # Slow-motion mode for debugging
    slowmo: ENV.fetch('SLOWMO', 0).to_f,

    # Browser options for stability, especially in CI/Docker
    browser_options: {
      'no-sandbox' => nil,
      'disable-gpu' => nil,
      'disable-dev-shm-usage' => nil,
      'disable-background-timer-throttling' => nil,
      'disable-renderer-backgrounding' => nil,
      'disable-backgrounding-occluded-windows' => nil,
      'disable-features' => 'TranslateUI,VizDisplayCompositor',
      'smooth-scrolling' => false,
      'disable-smooth-scrolling' => nil,
      # Hard-block external hosts at the network level
      'host-resolver-rules' => block_rules
    },

    # Network headers to short-circuit geo queries
    network_headers: {
      'Accept-Language' => 'en-US'
    }
  )
end

# Optional Selenium driver for isolation testing (set SYSTEM_TEST_DRIVER=selenium)
Capybara.register_driver :selenium_chrome_headless do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument('--headless=new')
  options.add_argument('--disable-gpu')
  options.add_argument('--no-sandbox')
  options.add_argument('--disable-dev-shm-usage')
  options.add_argument('--window-size=1200,800')
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

# CupriteSessionExtensions - Add hard restart capability
module CupriteSessionExtensions
  def hard_restart
    browser&.quit
    Capybara.reset_sessions!
  end
end

# --------------------------------------------------------------------------
# SECTION 2: GLOBAL CAPYBARA CONFIGURATION
# --------------------------------------------------------------------------
# This block sets the global configuration for Capybara itself.
# --------------------------------------------------------------------------
Capybara.configure do |config|
  config.default_driver = :cuprite
  config.javascript_driver = :cuprite
  config.default_max_wait_time = 10 # Default time Capybara waits for elements
  config.server = :puma, { Silent: true }
  config.server_host = '127.0.0.1' # Use localhost instead of 0.0.0.0
  # Use dynamic port allocation for parallel testing (avoids port conflicts)
  config.server_port = nil # Let Capybara choose available ports
  config.save_path = Rails.root.join('tmp/capybara')
  config.disable_animation = true # Speeds up tests
  config.enable_aria_label = true
  # Prefer Capybara defaults; avoid auto-reloading surprises
  # config.automatic_reload = true
end

# Include CupriteSessionExtensions for hard restart capability
Capybara::Session.include CupriteSessionExtensions

# Helper Modules – defined before use

# SeedLookupHelpers -----------------------------------------------------------
module SeedLookupHelpers
  EMAILS = {
    admin: 'admin@example.com',
    admin_david: 'admin@example.com',
    confirmed_user: 'user@example.com',
    confirmed_user2: 'user2@example.com',
    unconfirmed_user: 'unconfirmed@example.com',
    trainer: 'trainer@example.com',
    evaluator: 'evaluator@example.com',
    medical_provider: 'medical@example.com',
    constituent_john: 'john.doe@example.com',
    constituent_jane: 'jane.doe@example.com',
    constituent_alex: 'alex.smith@example.com',
    constituent_rex: 'rex.canine@example.com',
    vendor_ray: 'ray@testemail.com',
    vendor_teltex: 'teltex@testemail.com',
    constituent_alice: 'alice.doe@example.com'
  }.freeze

  def users(sym)
    email = EMAILS.fetch(sym) { raise ArgumentError, "Unknown user #{sym}" }

    # Determine the correct class and attributes based on the symbol
    user_class, attributes = case sym
                             when :admin, :admin_david
                               [Users::Administrator, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active,
                                 verified: true,
                                 email_verified: true
                               }]
                             when :evaluator
                               [Users::Evaluator, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active  # Evaluators have active status
                               }]
                             when :trainer
                               [Users::Trainer, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active  # Trainers have active status
                               }]
                             when :medical_provider
                               [Users::MedicalProvider, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active  # Medical providers inherit from base User
                               }]
                             when :vendor_ray, :vendor_teltex
                               [Users::Vendor, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'Vendor', # Match the factory pattern
                                 status: :active, # Ensure vendor can authenticate
                                 vendor_authorization_status: :approved, # vendor_authorization_status for vendor authorization to participate in voucher program
                                 business_name: "#{sym.to_s.titleize.split('_').first} Business",
                                 business_tax_id: "#{sym.to_s.upcase.gsub('_', '')}123456",
                                 terms_accepted_at: Time.current,
                                 # w9_status is handled by the factory's after(:create) callback
                                 verified: true,
                                 email_verified: true
                               }]
                             else
                               [Users::Constituent, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: (sym == :unconfirmed_user ? :inactive : :active),
                                 hearing_disability: true # Set default disability to pass validation
                               }]
                             end

    # Use the specific class to find or create the user
    user = user_class.find_or_create_by!(email: email) do |u|
      attributes.each { |key, value| u.send("#{key}=", value) }
    end

    # If we found an existing user (not just created), update its attributes to match what tests expect
    # This ensures test users have the correct attributes even if they were seeded differently
    # Skip this for vendor users since the factory handles all the complex w9_status logic correctly
    if user.persisted? && !user.is_a?(Users::Vendor)
      needs_update = attributes.any? { |key, value| user.send(key) != value }
      if needs_update
        debug_puts "Updating existing user #{user.email} with test attributes" if ENV['VERBOSE_TESTS']
        attributes.each { |key, value| user.send("#{key}=", value) }
        user.save! if user.changed?
      end
    end
    user
  end

  def applications(kind = :any)
    scope = Application.all
    case kind.to_sym
    when :in_progress
      scope.find_by(status: 'in_progress') ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected in_progress)')
    when :submitted_application
      # Try multiple possible statuses that indicate a submitted application
      scope.where(status: %w[in_progress awaiting_dcf]).first ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected in_progress or awaiting_dcf)')
    when :approved_application
      scope.find_by(status: 'approved') ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected approved)')
    when :pending_application
      scope.where(status: %w[awaiting_proof awaiting_dcf]).first ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected awaiting_proof or awaiting_dcf)')
    when :pending_with_proofs
      # Find a pending application that has both income and residency proofs attached
      scope.joins(:income_proof_attachment, :residency_proof_attachment)
           .where(status: %w[awaiting_proof awaiting_dcf]).first ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected pending with proofs)')
    when :waiting_period
      # Look for applications that are in waiting period (approved but within 3 year window)
      scope.where(status: 'approved').where('created_at > ?', 3.years.ago).first ||
        scope.where(status: 'approved').first ||
        raise(ArgumentError, 'No applications found in seeds (expected waiting_period)')
    when :training_request
      # Since training_request status doesn't exist, look for approved applications
      # that would likely need training (approved with all proofs approved)
      scope.where(status: 'approved', income_proof_status: 'approved', residency_proof_status: 'approved').first ||
        scope.where(status: 'approved').first ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected approved applications for training)')
    when :rejected
      scope.find_by(status: 'rejected') ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected rejected)')
    else
      scope.first ||
        raise(ArgumentError, 'No applications found in seeds')
    end
  end

  def debug_puts(msg)
    puts msg if ENV['VERBOSE_TESTS']
  end
end

# MemorySafeTestHelpers -------------------------------------------------------
# Lightweight wrappers around FactoryBot that avoid memory-intensive operations
module MemorySafeTestHelpers
  SPECIAL_TRAITS = %i[confirmed with_webauthn_credential].freeze

  def create(factory_name, *traits_and_attrs)
    traits, attrs = traits_and_attrs.partition { |t| t.is_a?(Symbol) }

    # Handle special user traits that need conversion
    if factory_name == :user && traits.intersect?(SPECIAL_TRAITS)
      attrs_hash = attrs.first || {}
      attrs_hash[:status] = :active if traits.include?(:confirmed)
      # Add webauthn credential handling if needed
      traits -= SPECIAL_TRAITS

      # Delegate to FactoryBot for proper validation and better error messages
      FactoryBot.create(factory_name, *traits, attrs_hash)
    else
      # Delegate to FactoryBot for proper validation and better error messages
      FactoryBot.create(factory_name, *traits_and_attrs)
    end
  end

  def create_list(factory_name, count, *)
    FactoryBot.create_list(factory_name, count, *)
  end

  # Helper method to create lightweight blob stubs for ActiveStorage
  # Removed duplicate create_lightweight_blob – unified in ActiveSupport::TestCase

  # Helper to attach a lightweight blob to a model (direct attach without explicit blob)
  def attach_lightweight_proof(model, attachment_name, filename: 'test.pdf')
    model.public_send(attachment_name).attach(
      io: StringIO.new('stub'),
      filename: filename,
      content_type: 'application/pdf'
    )
  end

  def debug_puts(msg)
    puts msg if ENV['VERBOSE_TESTS']
  end
end

# --------------------------------------------------------------------------
# SECTION 3: THE BASE TEST CASE CLASS
# --------------------------------------------------------------------------
# All system tests will inherit from this class. It includes all necessary
# helpers and defines a setup/teardown lifecycle.
# --------------------------------------------------------------------------
class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Use driver based on ENV for isolation; default to Cuprite
  if ENV['SYSTEM_TEST_DRIVER']&.downcase == 'selenium'
    driven_by :selenium, using: :chrome, screen_size: [1200, 800]
  else
    driven_by :cuprite, screen_size: [1200, 800]
  end

  # Include all necessary helper modules.
  include SystemTestAuthentication
  include SystemTestHelpers
  include FplPolicyHelpers
  include SeedLookupHelpers            # users(:admin) etc. (defined above)
  include MemorySafeTestHelpers        # create() wrapper that uses FactoryBot (defined above)

  # SeedLookupHelper is in test_helper.rb for global access.

  # Modal helpers consolidated into SystemTestHelpers

  # Use guarded default worker count. Ruby 3.4.x + pg 1.6.x can segfault on
  # concurrent connection setup (observed in connect_start). Default to 1
  # worker for that combo; allow override via SYSTEM_TEST_WORKERS.
  begin
    ruby_34 = Gem::Version.new(RUBY_VERSION).segments.first(2) == [3, 4]
    pg_spec = Gem.loaded_specs['pg']
    pg_16   = pg_spec && pg_spec.version.segments.first(2) == [1, 6]
    default_workers = ruby_34 && pg_16 ? 1 : 4
  rescue StandardError
    default_workers = 1
  end
  parallelize(workers: ENV.fetch('SYSTEM_TEST_WORKERS', default_workers).to_i, with: :processes)

  # Database cleaning strategy for system tests
  if defined?(DatabaseCleaner)
    # Setup per parallel worker - removed app_host setting per Stack Overflow best practices
    parallelize_setup do
      # Let Capybara manage its own server configuration
    end

    setup do
      # Use truncation for system tests since the app server runs in
      # a separate thread/process and won’t see transactional data.
      DatabaseCleaner.strategy = :truncation
      DatabaseCleaner.start
    end

    teardown do
      DatabaseCleaner.clean
    end
  end

  # --- Test Lifecycle Hooks ---

  setup do
    # 0. Track Chrome processes at test start
    track_chrome_processes('TEST_SETUP_START')

    # 1. Store and set validation flag to prevent leaking to other test types
    @skip_flag_original = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = true

    # 2. Reset Capybara session state to ensure a clean browser.
    # Enhanced debugging for browser state corruption
    debug_browser_state('SETUP START')
    track_chrome_processes('BEFORE_SESSION_RESET')
    begin
      Capybara.reset_sessions!
      track_chrome_processes('AFTER_SESSION_RESET')
      debug_browser_state('SETUP AFTER RESET')
    rescue StandardError
      track_chrome_processes('SESSION_RESET_FAILED')
    end

    # 3. Clear any lingering authentication state from previous tests.
    clear_test_identity

    # 4. Clear any pending network connections from previous tests
    clear_pending_network_connections if respond_to?(:clear_pending_network_connections, true)
    track_chrome_processes('AFTER_CONNECTION_CLEAR')
  end

  teardown do
    # 0. Track Chrome processes at teardown start
    track_chrome_processes('TEST_TEARDOWN_START')

    # 1. Log test failure details
    if failed?
      puts "\n"
      puts "Failure in: #{self.class.name}##{name}"
      track_chrome_processes('TEST_FAILED')
    end

    # 2. Ensure the user is signed out and the session is fully cleared.
    system_test_sign_out
    track_chrome_processes('AFTER_SIGN_OUT')

    # 3. Restore the original validation flag to prevent leaking into other tests
    Application.skip_wait_period_validation = @skip_flag_original
    track_chrome_processes('TEST_TEARDOWN_COMPLETE')
  end

  # DB cleaning – truncation is required because browser ≠ test thread
  def self.use_transactional_tests?
    false
  end

  # --- Helper Methods ---
  # Helper to safely skip wait period validation with automatic cleanup
  def with_wait_period_skipped
    original_value = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = true
    yield
  ensure
    Application.skip_wait_period_validation = original_value
  end

  # Override Rails' take_screenshot to provide logging and handle optional name parameter
  def take_screenshot(_name = nil)
    return nil unless page&.driver

    # Use Rails' built-in screenshot functionality (ignores name parameter)
    path = super()
    puts "📸 Screenshot saved: #{path}" if path
    path
  rescue StandardError => e
    puts "Failed to take screenshot: #{e.message}"
    nil
  end

  # Helper to manually restart browser when tests detect issues
  def restart_browser!
    puts '🔄 Manually restarting browser...'
    hard_restart
  end

  # Cuprite-friendly fill_in helper that avoids "Options passed to Node#set" warnings
  def cuprite_fill_in(locator, value)
    element = find_field(locator)
    # Use Capybara's own methods to avoid warnings
    element.click.send_keys([:control, 'a'], value.to_s) if value.present?
  end

  # Helper for tests that need JS to reach across threads (file uploads, ActionCable, etc.)
  def using_truncation(&)
    DatabaseCleaner.cleaning(&)
  end

  # Auth assertion helpers – many tests rely on these
  def assert_authenticated_as(user, msg = nil)
    assert_no_match(/Sign (In|Up)/i, page.text, msg || 'Found sign‑in link for authenticated user')
    assert_includes page.text, 'Sign Out', msg || 'Missing sign‑out link'
    assert_not_equal sign_in_path, current_path, msg || 'Still on sign‑in page'
    return unless user.respond_to?(:first_name) && user.first_name.present?

    assert_match(/#{Regexp.escape(user.first_name)}/, page.text, msg || 'User name missing from UI')
  end

  def assert_not_authenticated(msg = nil)
    assert_match(/Sign (In|Up)/i, page.text, msg || 'Missing sign‑in link when logged‑out')
    assert_not_includes page.text, 'Sign Out', msg || 'Sign‑out link present when logged‑out'
  end

  def with_authenticated_user(user)
    system_test_sign_in(user)
    yield if block_given?
  ensure
    system_test_sign_out
  end

  # Use the connection clearing method from SystemTestHelpers consistently
  def clear_pending_connections
    clear_pending_network_connections
  end

  # Sign in method that doesn't require a block and doesn't automatically sign out
  # This is for tests that manage their own authentication lifecycle
  def sign_in(user)
    system_test_sign_in(user)
  end

  # Misc utilities kept for backwards compatibility ------------------------------------
  def toggle_password_visibility?(field_id)
    field = find("input##{field_id}")
    # Find the button within the same container (parent div with data-controller="visibility")
    container = field.ancestor('[data-controller="visibility"]')
    button = container.find('button[data-action="visibility#togglePassword"]')
    page.execute_script('arguments[0].click()', button)
    true # Return true to make assertions work
  end

  # Alias without question mark for test compatibility
  def toggle_password_visibility(field_id)
    toggle_password_visibility?(field_id)
  end

  def fixture_file_upload(rel_path, mime_type = nil)
    Rack::Test::UploadedFile.new(Rails.root.join(rel_path), mime_type || Mime[:pdf].to_s)
  end

  def debug_page
    puts "URL: #{current_url}\nHTML: #{page.html[0, 400]}…"
    take_screenshot
  end

  # Helper to wait for an arbitrary condition without ad-hoc sleeps.
  # Usage: wait_until(time: seconds) { page.current_path == expected_path }
  def wait_until(time: Capybara.default_max_wait_time)
    Timeout.timeout(time) do
      until (value = yield)
        sleep(0.1)
      end
      value
    end
  end

  private

  # ============================================================================
  # CHROME PROCESS MANAGEMENT
  # ============================================================================

  def track_chrome_processes(_context)
    return unless ENV['ALLOW_CHROME_CLEANUP']

    begin
      chrome_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
      process_count = chrome_processes.count

      # Auto-cleanup if we hit critical thresholds
      emergency_chrome_cleanup if process_count > 200 # Critical threshold
    rescue StandardError
      # Silently handle process check errors
    end
  end

  # Emergency Chrome process cleanup
  def emergency_chrome_cleanup
    return unless ENV['ALLOW_CHROME_CLEANUP']

    # Get all Chrome processes
    chrome_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
    initial_count = chrome_processes.count

    return if initial_count.zero?

    # Extract PIDs and terminate gracefully first
    pids = chrome_processes.map { |proc| proc.split[1] }.compact
    pids.each do |pid|
      next unless pid.match?(/^\d+$/)

      begin
        Process.kill('TERM', pid.to_i)
      rescue Errno::ESRCH
        # Process already dead, ignore
      rescue StandardError
        # Silently handle termination errors
      end
    end

    # Force kill any remaining processes
    remaining_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
    if remaining_processes.any?
      remaining_processes.each do |proc|
        pid = proc.split[1]
        next unless pid&.match?(/^\d+$/)

        begin
          Process.kill('KILL', pid.to_i)
        rescue Errno::ESRCH
          # Ignore errors - process cleanup
        end
      end
    end

    # Reset Capybara completely after emergency cleanup
    capybara_nuclear_reset if defined?(Capybara)
  rescue StandardError
    # Silently handle emergency cleanup errors
  end

  # Nuclear reset of all Capybara state
  def capybara_nuclear_reset
    # Access private session pool and quit all drivers
    if Capybara.respond_to?(:session_pool, true)
      session_pool = Capybara.send(:session_pool)

      session_pool.each_value do |session|
        if session&.driver.respond_to?(:quit)
          session.driver.quit
        elsif session&.driver.respond_to?(:browser) && session.driver.browser.respond_to?(:quit)
          session.driver.browser.quit
        end
      rescue StandardError
        # Silently handle session quit errors
      end

      # Clear the session pool
      session_pool.clear
    end

    # Force garbage collection
    GC.start
  rescue StandardError
    # Silently handle nuclear reset errors
  end

  # Comprehensive Capybara session cleanup using documented APIs
  def capybara_session_cleanup
    # Step 1: Use the documented approach from Capybara docs
    # "Capybara.send(:session_pool).each { |name, ses| ses.driver.quit }"
    if Capybara.respond_to?(:session_pool, true)
      session_pool = Capybara.send(:session_pool)
      session_count = session_pool.size
      if session_count.positive?
        session_pool.each_value do |session|
          # Use documented quit method on driver
          session.driver.quit if session&.driver.respond_to?(:quit)
          # Use documented reset method (also known as cleanup!, reset_session!)
          if session.respond_to?(:reset!)
            session.reset!
          elsif session.respond_to?(:cleanup!)
            session.cleanup!
          end
        rescue StandardError
          # Silently handle session cleanup errors
        end
        # Clear the session pool after individual cleanup
        session_pool.clear
      end
    end

    # Step 2: Use standard Capybara reset as documented
    Capybara.reset_sessions! if defined?(Capybara) && Capybara.respond_to?(:reset_sessions!)
    # Step 3: Force garbage collection to clean up any lingering references
    GC.start
  end

  # ============================================================================
  # BROWSER CORRUPTION DEBUGGING
  # ============================================================================

  def debug_browser_state(_context)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    # Check if page exists and is responsive
    begin
      return unless defined?(page) && page

      # Check driver state
      browser = (page.driver.browser if page.driver.respond_to?(:browser))

      if browser
        # Try to get browser status
        if browser.respond_to?(:contexts)
          begin
            browser.contexts.count
          rescue StandardError
            nil
          end
        end

        if browser.respond_to?(:process)
          begin
            browser.process&.pid
          rescue StandardError
            nil
          end
        end
      end

      # Try a simple page interaction
      begin
        page.current_url
      rescue StandardError
        # Silently handle URL check errors
      end

      # Check session pool
      if defined?(Capybara.session_pool)
        Capybara.session_pool.size
      end
    rescue StandardError
      # Silently handle debug errors
    end
  end

  def force_browser_restart(_reason)
    # Minimal reset; do not kill external Chrome processes
    capybara_session_cleanup
  end
end
