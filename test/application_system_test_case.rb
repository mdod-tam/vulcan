# frozen_string_literal: true

# rubocop:disable Style/OneClassPerFile -- system test base co-locates helper modules by design.

require 'test_helper'
require 'json'
require 'socket'
require 'capybara/cuprite'
begin
  require 'chunky_png'
rescue LoadError
  # Blank screenshot detection is skipped when the PNG parser is unavailable.
end

# Global Capybara configuration
Capybara.configure do |config|
  config.default_driver = :cuprite
  config.javascript_driver = :cuprite
  config.default_max_wait_time = 10
  config.server = :puma, { Silent: true }
  config.server_host = '127.0.0.1'
  # Dynamic ports avoid conflicts between parallel workers.
  config.server_port = nil
  config.save_path = Rails.root.join('tmp/capybara')
  config.disable_animation = true
  config.enable_aria_label = true
end

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
                                 status: :active
                               }]
                             when :trainer
                               [Users::Trainer, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active
                               }]
                             when :medical_provider
                               [Users::MedicalProvider, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: :active
                               }]
                             when :vendor_ray, :vendor_teltex
                               [Users::Vendor, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'Vendor',
                                 status: :active,
                                 vendor_authorization_status: :approved,
                                 business_name: "#{sym.to_s.titleize.split('_').first} Business",
                                 business_tax_id: "#{sym.to_s.upcase.gsub('_', '')}123456",
                                 terms_accepted_at: Time.current,
                                 verified: true,
                                 email_verified: true
                               }]
                             else
                               [Users::Constituent, {
                                 password: 'password123',
                                 first_name: sym.to_s.titleize.split('_').first,
                                 last_name: 'User',
                                 status: (sym == :unconfirmed_user ? :inactive : :active),
                                 hearing_disability: true # This default satisfies the disability validation when it applies.
                               }]
                             end

    user = user_class.find_or_create_by!(email: email) do |u|
      attributes.each { |key, value| u.send("#{key}=", value) }
    end

    # Normalize test attributes, but preserve the stored vendor state.
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
    # Prefer the requested state, then use the branch's fallback when seeds lack a match.
    scope = Application.all
    case kind.to_sym
    when :in_progress
      scope.find_by(status: 'in_progress') ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected in_progress)')
    when :submitted_application
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
      scope.joins(:income_proof_attachment, :residency_proof_attachment)
           .where(status: %w[awaiting_proof awaiting_dcf]).first ||
        scope.first ||
        raise(ArgumentError, 'No applications found in seeds (expected pending with proofs)')
    when :waiting_period
      scope.where(status: 'approved').where('created_at > ?', 3.years.ago).first ||
        scope.where(status: 'approved').first ||
        raise(ArgumentError, 'No applications found in seeds (expected waiting_period)')
    when :training_request
      # There is no training_request status. Prefer approved income and residency proofs.
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

module MemorySafeTestHelpers
  SPECIAL_TRAITS = %i[confirmed with_webauthn_credential].freeze

  def create(factory_name, *traits_and_attrs)
    traits, attrs = traits_and_attrs.partition { |t| t.is_a?(Symbol) }

    if factory_name == :user && traits.intersect?(SPECIAL_TRAITS)
      attrs_hash = attrs.first || {}
      attrs_hash[:status] = :active if traits.include?(:confirmed)
      # TODO: Add support for the :with_webauthn_credential trait.
      traits -= SPECIAL_TRAITS

      FactoryBot.create(factory_name, *traits, attrs_hash)
    else
      FactoryBot.create(factory_name, *traits_and_attrs)
    end
  end

  def create_list(factory_name, count, *)
    FactoryBot.create_list(factory_name, count, *)
  end

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

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Rails registers this driver and replaces any prior :cuprite registration.
  # Heroku CI sets CHROME_NO_SANDBOX for the chrome-for-testing buildpack.
  driven_by :cuprite, screen_size: [1200, 800],
                      options: { js_errors: true, headless: %w[false 0].exclude?(ENV.fetch('HEADLESS', 'true')),
                                 browser_options: ENV['CHROME_NO_SANDBOX'] == 'true' ? { 'no-sandbox' => nil } : {} }

  include SystemTestAuthentication
  include SystemTestHelpers
  include FplPolicyHelpers
  include SeedLookupHelpers
  include MemorySafeTestHelpers

  # Ruby 3.4 with pg 1.6 had segfaults in connect_start during concurrent connection setup.
  # That combination defaults to one worker. SYSTEM_TEST_WORKERS overrides the default.
  begin
    ruby_34 = Gem::Version.new(RUBY_VERSION).segments.first(2) == [3, 4]
    pg_spec = Gem.loaded_specs['pg']
    pg_16   = pg_spec && pg_spec.version.segments.first(2) == [1, 6]
    default_workers = ruby_34 && pg_16 ? 1 : 4
  rescue StandardError
    default_workers = 1
  end
  parallelize(workers: ENV.fetch('SYSTEM_TEST_WORKERS', default_workers).to_i, with: :processes)

  if defined?(DatabaseCleaner)
    parallelize_setup do
      # Server configuration stays with Capybara.
    end

    setup do
      # The app server uses another connection and cannot read uncommitted test data.
      DatabaseCleaner.strategy = :truncation
      DatabaseCleaner.start
    end

    teardown do
      DatabaseCleaner.clean
    end
  end

  # Test lifecycle

  setup do
    track_chrome_processes('TEST_SETUP_START')

    # The saved validation flag lets teardown restore the prior value.
    @skip_flag_original = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = true

    debug_browser_state('SETUP START')
    track_chrome_processes('BEFORE_SESSION_RESET')
    begin
      Capybara.reset_sessions!
      track_chrome_processes('AFTER_SESSION_RESET')
      debug_browser_state('SETUP AFTER RESET')
    rescue StandardError
      track_chrome_processes('SESSION_RESET_FAILED')
    end

    clear_test_identity

    clear_pending_network_connections if respond_to?(:clear_pending_network_connections, true)
    track_chrome_processes('AFTER_CONNECTION_CLEAR')

    install_stimulus_error_reporting
  end

  # Stimulus catches controller exceptions and calls window.onerror directly.
  # Rethrow only that call so Cuprite enforces it like any uncaught exception.
  def install_stimulus_error_reporting
    return unless page.driver.is_a?(Capybara::Cuprite::Driver)

    page.driver.browser.page.command('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
      window.__systemTestErrors = [];
      window.onerror = function(message, source, line, column, error) {
        window.__systemTestErrors.push(String(error || message));
        if (source === "" && line === 0) {
          setTimeout(function() { throw error || new Error(message); }, 0);
        }
      };
    JS
  end

  teardown do
    track_chrome_processes('TEST_TEARDOWN_START')

    if failed?
      puts "\n"
      puts "Failure in: #{self.class.name}##{name}"
      track_chrome_processes('TEST_FAILED')
    end

    system_test_sign_out
    track_chrome_processes('AFTER_SIGN_OUT')

    # Restore the original flag to avoid leakage into later tests.
    Application.skip_wait_period_validation = @skip_flag_original
    track_chrome_processes('TEST_TEARDOWN_COMPLETE')
  end

  def self.use_transactional_tests?
    false
  end

  def with_wait_period_skipped
    original_value = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = true
    yield
  ensure
    Application.skip_wait_period_validation = original_value
  end

  # This override preserves named screenshot calls and Rails' html: and screenshot: keywords.
  def take_screenshot(name = nil, html: false, screenshot: nil)
    return nil unless page&.driver

    @screenshot_artifact_label = name.presence
    wait_for_meaningful_page_content(timeout: 3) if respond_to?(:wait_for_meaningful_page_content)

    super(html: html, screenshot: screenshot)
    path = image_path
    write_screenshot_sidecar(path, label: @screenshot_artifact_label, html_saved: screenshot_html_enabled?(html))
    puts screenshot_log_message(path)
    path
  rescue StandardError => e
    puts "Failed to take screenshot: #{e.message}"
    nil
  ensure
    @screenshot_artifact_label = nil
  end

  def take_failed_screenshot
    return unless failed? && supports_screenshot? && Capybara::Session.instance_created?

    unless browser_page_visited?
      puts "Skipping failure screenshot for #{self.class.name}##{name}: no browser page was visited"
      return
    end

    super
  end

  def capture_browser_recovery_diagnostics(reason, error: nil)
    return if @capturing_browser_recovery_diagnostics

    @capturing_browser_recovery_diagnostics = true
    detail = error ? "#{reason}: #{error.class} - #{error.message}" : reason
    puts "Capturing browser diagnostics before recovery: #{detail}" if ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']
    take_screenshot("recovery-#{reason}", html: true)
  rescue StandardError => e
    puts "Failed to capture browser recovery diagnostics: #{e.message}" if ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']
  ensure
    @capturing_browser_recovery_diagnostics = false
  end

  def restart_browser!
    puts '🔄 Manually restarting browser...'
    capture_browser_recovery_diagnostics('manual_restart')
    page.driver.restart
    Capybara.reset_sessions!
  end

  # send_keys avoids Cuprite's "Options passed to Node#set" warnings.
  def cuprite_fill_in(locator, value)
    element = find_field(locator)
    element.click.send_keys([:control, 'a'], value.to_s) if value.present?
  end

  def using_truncation(&)
    DatabaseCleaner.cleaning(&)
  end

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

  def clear_pending_connections
    clear_pending_network_connections
  end

  # Callers manage sign-out for this helper.
  def sign_in(user)
    system_test_sign_in(user)
  end

  def toggle_password_visibility?(field_id)
    field = find("input##{field_id}")
    container = field.ancestor('[data-controller="visibility"]')
    button = container.find('button[data-action="visibility#togglePassword"]')
    page.execute_script('arguments[0].click()', button)
    true
  end

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

  # These overrides use Rails' private ScreenshotHelper so images, HTML, and sidecars share one artifact name.
  def image_name
    label = @screenshot_artifact_label
    return super if label.blank?

    sanitized_label = label.to_s.gsub(/[^\w]+/, '-').gsub(/^-|-$/, '').presence
    "#{unique}_#{sanitized_label || method_name.gsub(/[^\w]+/, '-')}"[0...225]
  end

  def screenshot_html_enabled?(html_argument)
    html_argument || ENV['RAILS_SYSTEM_TESTING_SCREENSHOT_HTML'] == '1'
  end

  def screenshot_sidecar_path
    "#{absolute_path}.json"
  end

  def write_screenshot_sidecar(path, label:, html_saved:)
    state = screenshot_browser_state
    blank_analysis = analyze_screenshot_blankness(path)
    stimulus = screenshot_stimulus_state
    js_errors = screenshot_js_errors
    unusable_reasons = screenshot_unusable_reasons(state, blank_analysis, stimulus: stimulus, js_errors: js_errors)

    File.write(
      screenshot_sidecar_path,
      JSON.pretty_generate(
        generated_at: Time.current.iso8601,
        test_class: self.class.name,
        test_name: name,
        label: label,
        artifact_usable_for_llm_qa: unusable_reasons.empty?,
        unusable_reasons: unusable_reasons,
        screenshot_path: path,
        html_path: html_saved ? html_path : nil,
        browser_state: state,
        viewport_analysis: blank_analysis,
        stimulus: stimulus,
        js_errors: js_errors
      )
    )
  rescue StandardError => e
    puts "Failed to write screenshot sidecar: #{e.message}" if ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']
  end

  def screenshot_log_message(path)
    sidecar = screenshot_sidecar_path
    return "Screenshot saved: #{path} (sidecar: #{sidecar})" unless File.exist?(sidecar)

    sidecar_json = JSON.parse(File.read(sidecar))
    return "Screenshot saved: #{path} (sidecar: #{sidecar})" if sidecar_json['artifact_usable_for_llm_qa']

    reasons = Array(sidecar_json['unusable_reasons']).join(', ')
    "Screenshot saved but marked QA-unusable: #{path} (#{reasons}; sidecar: #{sidecar})"
  rescue StandardError
    "Screenshot saved: #{path}"
  end

  def screenshot_stimulus_state
    page.evaluate_script(<<~JS)
      (() => {
        const declared = [], connected = [], missing = [];
        document.querySelectorAll("[data-controller]").forEach(element => {
          element.dataset.controller.split(/\\s+/).filter(Boolean).forEach(identifier => {
            declared.push(identifier);
            if (window.Stimulus?.getControllerForElementAndIdentifier(element, identifier)) {
              connected.push(identifier);
            } else {
              missing.push(identifier);
            }
          });
        });
        return {
          router_read: !!window.Stimulus,
          declared: [...new Set(declared)].sort(),
          connected: [...new Set(connected)].sort(),
          declared_not_connected: [...new Set(missing)].sort()
        };
      })()
    JS
  rescue StandardError => e
    { 'router_read' => false, 'declared_not_connected' => nil, 'read_error' => e.message }
  end

  def screenshot_js_errors
    page.evaluate_script('window.__systemTestErrors || null')
  rescue StandardError
    nil
  end

  def screenshot_browser_state
    page.evaluate_script(<<~JS, meaningful_page_content_selector)
      (function(selector) {
        var meaningfulMatches = [];
        try {
          meaningfulMatches = Array.prototype.slice.call(document.querySelectorAll(selector)).map(function(element) {
            return {
              tag: element.tagName.toLowerCase(),
              id: element.id || null,
              testid: element.getAttribute("data-testid"),
              text: (element.innerText || element.textContent || "").trim().slice(0, 120)
            };
          }).slice(0, 10);
        } catch (error) {}

        return {
          url: window.location.href,
          path: window.location.pathname,
          title: document.title,
          ready_state: document.readyState,
          has_body: !!document.body,
          body_text_length: document.body ? (document.body.innerText || "").trim().length : 0,
          meaningful_selector: selector,
          meaningful_match_count: meaningfulMatches.length,
          meaningful_matches: meaningfulMatches
        };
      })(arguments[0]);
    JS
  rescue StandardError => e
    {
      url: safe_current_browser_url,
      path: nil,
      title: nil,
      ready_state: nil,
      has_body: false,
      body_text_length: 0,
      meaningful_selector: meaningful_page_content_selector,
      meaningful_match_count: 0,
      meaningful_matches: [],
      error: "#{e.class}: #{e.message}"
    }
  end

  def screenshot_unusable_reasons(state, blank_analysis, stimulus:, js_errors:)
    reasons = []
    reasons << 'about_blank_url' if state[:url] == 'about:blank' || state['url'] == 'about:blank'
    reasons << 'no_meaningful_content_anchor' if (state[:meaningful_match_count] || state['meaningful_match_count']).to_i.zero?
    reasons << 'empty_body_text' if (state[:body_text_length] || state['body_text_length']).to_i.zero?
    reasons << 'solid_color_viewport' if blank_analysis[:solid_color] || blank_analysis['solid_color']
    reasons << 'test_failed' if failed?
    reasons << 'runtime_errors_not_captured' if js_errors.nil?
    reasons << 'runtime_errors' if js_errors.present?
    reasons << 'stimulus_unavailable' unless stimulus['router_read']
    reasons << 'controllers_not_connected' if stimulus['declared_not_connected'].present?
    reasons
  end

  def analyze_screenshot_blankness(path)
    return { solid_color: nil, reason: 'image_missing' } if path.blank? || !File.exist?(path)
    return { solid_color: nil, reason: 'chunky_png_unavailable' } unless defined?(ChunkyPNG)

    image = ChunkyPNG::Image.from_file(path)
    colors = sampled_png_colors(image)

    {
      solid_color: colors.size <= 2,
      sampled_color_count: colors.size,
      width: image.width,
      height: image.height
    }
  rescue StandardError => e
    { solid_color: nil, reason: "#{e.class}: #{e.message}" }
  end

  def sampled_png_colors(image)
    x_step = [(image.width / 32.0).ceil, 1].max
    y_step = [(image.height / 32.0).ceil, 1].max
    colors = {}

    (0...image.height).step(y_step) do |y|
      (0...image.width).step(x_step) do |x|
        colors[image[x, y]] = true
        return colors if colors.size > 2
      end
    end

    colors
  end

  def browser_page_visited?
    url = safe_current_browser_url
    url.present? && url != 'about:blank'
  end

  def safe_current_browser_url
    page.current_url
  rescue StandardError
    nil
  end

  # Chrome process management

  def track_chrome_processes(_context)
    return unless ENV['ALLOW_CHROME_CLEANUP']

    begin
      chrome_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
      process_count = chrome_processes.count

      emergency_chrome_cleanup if process_count > 200
    rescue StandardError
      # Process inspection errors do not interrupt the test lifecycle.
    end
  end

  def emergency_chrome_cleanup
    return unless ENV['ALLOW_CHROME_CLEANUP']

    chrome_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
    initial_count = chrome_processes.count

    return if initial_count.zero?

    pids = chrome_processes.map { |proc| proc.split[1] }.compact
    pids.each do |pid|
      next unless pid.match?(/^\d+$/)

      begin
        Process.kill('TERM', pid.to_i)
      rescue Errno::ESRCH
        # The process can exit after the PID list is read.
      rescue StandardError
        # Cleanup continues with the remaining PIDs after a TERM failure.
      end
    end

    remaining_processes = `ps aux | grep -i chrome | grep -v grep`.split("\n")
    if remaining_processes.any?
      remaining_processes.each do |proc|
        pid = proc.split[1]
        next unless pid&.match?(/^\d+$/)

        begin
          Process.kill('KILL', pid.to_i)
        rescue Errno::ESRCH
          # The process can exit before the KILL request.
        end
      end
    end

    capybara_nuclear_reset if defined?(Capybara)
  rescue StandardError
    # Emergency cleanup errors do not interrupt the test lifecycle.
  end

  def capybara_nuclear_reset
    if Capybara.respond_to?(:session_pool, true)
      session_pool = Capybara.send(:session_pool)

      session_pool.each_value do |session|
        if session&.driver.respond_to?(:quit)
          session.driver.quit
        elsif session&.driver.respond_to?(:browser) && session.driver.browser.respond_to?(:quit)
          session.driver.browser.quit
        end
      rescue StandardError
        # One failed quit does not stop cleanup of the remaining sessions.
      end

      session_pool.clear
    end

    GC.start
  rescue StandardError
    # Recovery errors do not interrupt the test lifecycle.
  end

  def capybara_session_cleanup
    # Capybara cleanup pattern: Capybara.send(:session_pool).each { |name, ses| ses.driver.quit }
    if Capybara.respond_to?(:session_pool, true)
      session_pool = Capybara.send(:session_pool)
      session_count = session_pool.size
      if session_count.positive?
        session_pool.each_value do |session|
          session.driver.quit if session&.driver.respond_to?(:quit)
          if session.respond_to?(:reset!)
            session.reset!
          elsif session.respond_to?(:cleanup!)
            session.cleanup!
          end
        rescue StandardError
          # One session cleanup error does not stop cleanup of other sessions.
        end
        session_pool.clear
      end
    end

    Capybara.reset_sessions! if defined?(Capybara) && Capybara.respond_to?(:reset_sessions!)
    GC.start
  end

  # Browser diagnostics

  def debug_browser_state(_context)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    begin
      return unless defined?(page) && page

      browser = (page.driver.browser if page.driver.respond_to?(:browser))

      if browser
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

      begin
        page.current_url
      rescue StandardError
        # A failed URL read does not stop the remaining diagnostics.
      end

      if defined?(Capybara.session_pool)
        Capybara.session_pool.size
      end
    rescue StandardError
      # Diagnostic errors do not interrupt the test lifecycle.
    end
  end

  def force_browser_restart(reason)
    # Limit recovery to Capybara sessions. External Chrome processes stay alive.
    capture_browser_recovery_diagnostics(reason)
    capybara_session_cleanup
  end
end
# rubocop:enable Style/OneClassPerFile
