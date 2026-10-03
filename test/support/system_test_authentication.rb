# frozen_string_literal: true

require 'timeout'

# UI sign-in and sign-out helpers with browser recovery.
module SystemTestAuthentication
  extend ActiveSupport::Concern
  include AuthenticationCore

  def with_browser_rescue(max_retries: 2)
    tries = 0
    begin
      yield
    rescue Ferrum::DeadBrowserError, Ferrum::BrowserError, Ferrum::NodeNotFoundError, Ferrum::TimeoutError => e
      raise if (tries += 1) > max_retries

      warn "🔄 #{e.class} - restarting browser session (attempt #{tries})"

      if respond_to?(:force_browser_restart, true)
        force_browser_restart("authentication_rescue_#{tries}")
      else
        Capybara.reset_sessions!
        clear_pending_network_connections if respond_to?(:clear_pending_network_connections, true)
      end
      retry
    end
  end

  def system_test_sign_in(user, verify_path: nil)
    debug_authentication_state('SIGN_IN_START', user)

    # Authentication indicators require page content instead of about:blank.
    visit sign_in_path
    assert_selector('body', wait: 10)

    begin
      if page.has_text?('Sign Out', wait: 1)
        debug_puts "Already signed in. Skipping sign-in for #{user.email}."
        debug_authentication_state('SIGN_IN_SKIP', user)
        return
      end
    rescue Ferrum::TimeoutError => e
      debug_authentication_corruption('SIGN_IN_CHECK_TIMEOUT', e, user)
      force_browser_restart('sign_in_timeout_recovery') if respond_to?(:force_browser_restart)
    rescue StandardError => e
      debug_authentication_corruption('SIGN_IN_CHECK_ERROR', e, user)
      debug_puts "⚠️  Authentication state check failed (#{e.class}: #{e.message}) but browser appears responsive. " \
                 'This likely indicates a stale node reference or timing issue. Proceeding with fresh sign-in attempt ' \
                 "for #{user.email} after visiting #{sign_in_path}. Current URL: #{begin
                   page.current_url
                 rescue StandardError
                   'UNKNOWN'
                 end}"
    end

    if page.driver.is_a?(Capybara::RackTest::Driver)
      page.set_rack_session({})
    else
      page.execute_script('sessionStorage.clear(); localStorage.clear();')
    end
    wait_for_stimulus_controller('visibility')

    # Test-only skip_2fa bypasses MFA enrollment and the guard for flow initiation.
    # Sign-in still verifies existing credentials.
    if page.driver.is_a?(Capybara::RackTest::Driver)
      page.set_rack_session(skip_2fa: true)
    else
      # A synchronous request sets the bypass before form submission.
      page.execute_script(<<~JS)
        try {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/test/set_session', false); // synchronous
          xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
          xhr.send('skip_2fa=true');
        } catch(e) { /* no-op */ }
      JS
    end

    assert_selector('form[action="/sign_in"]', wait: 10)

    within('form[action="/sign_in"]') do
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    # Wait for navigation or form replacement. Do not refresh the page.
    using_wait_time(10) do
      expected_dashboard_path = user_dashboard_path(user)
      page.has_current_path?(expected_dashboard_path, wait: 6) || has_no_selector?('form[action="/sign_in"]', wait: 6)
    end

    expected_dashboard_path = user_dashboard_path(user)

    using_wait_time(10) do
      if verify_path.present? && page.has_current_path?(verify_path, wait: 5)
        # The expected verification page is already open.
      elsif dashboard_path_reached?(user, wait: 8)
        # The dashboard is already open.
      elsif page.has_text?(I18n.t('controllers.sessions.invalid_credentials'), wait: 2)
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - invalid credentials detected."
      elsif page.has_css?('.flash-message, [role="alert"], .alert, .notice', wait: 2)
        flash_text = page.find('.flash-message, [role="alert"], .alert, .notice', wait: 1).text

        if flash_text.include?('Signed in successfully') || flash_text.include?('signed in')
          page.has_current_path?(expected_dashboard_path, wait: 5)
        else
          take_screenshot
          raise "❌ Sign-in failed for #{user.email} - error in flash message: #{flash_text}"
        end
      elsif current_path == sign_in_path
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - still on sign-in page after waiting for redirect."
      end
    rescue Capybara::ElementNotFound => e
      if current_path == expected_dashboard_path
        debug_puts 'Authentication successful despite Capybara timeout - on correct dashboard'
      else
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - timeout waiting for redirect. Current path: #{current_path}"
      end
    end

    if verify_path.present?
      assert_current_path(verify_path, wait: 10)
      assert_selector('form', wait: 10)
      debug_puts "Successfully redirected to verification page for #{user.email}"
    elsif current_path&.match?(%r{/two_factor_authentication/verify})
      assert_selector('form', wait: 10)
      debug_puts "User #{user.email} has 2FA enabled, on verification page: #{current_path}"
    else
      assert_dashboard_landing!(user)
      wait_for_stimulus_controller('forms') if has_selector?('[data-controller*="forms"]', wait: 1)
      debug_puts "Successfully signed in as #{user.email}"
    end
  rescue Capybara::ElementNotFound => e
    debug_puts "Sign-in failed: #{e.message}. Current page: #{current_path}"
    take_screenshot
    raise
  rescue Ferrum::NodeNotFoundError => e
    debug_puts "Node not found error during sign-in: #{e.message}. Current page: #{current_path}"
    take_screenshot
    # Retry once after clearing the browser session.
    debug_puts 'Retrying sign-in with fresh session...'
    Capybara.reset_sessions!
    clear_pending_network_connections

    visit sign_in_path
    assert_selector('form[action="/sign_in"]', wait: 10)
    wait_for_stimulus_controller('visibility')

    within('form[action="/sign_in"]') do
      fill_in 'contact-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    wait_for_page_stable(timeout: 15)
    wait_for_turbo(timeout: 10)

    if verify_path.present?
      assert_current_path(verify_path, wait: 10)
      assert_selector('form', wait: 10)
      debug_puts "Successfully redirected to verification page for #{user.email} on retry"
    elsif current_path&.match?(%r{/two_factor_authentication/verify})
      assert_selector('form', wait: 10)
      debug_puts "User #{user.email} has 2FA enabled, on verification page: #{current_path} on retry"
    else
      assert_dashboard_landing!(user)
      wait_for_stimulus_controller('forms') if has_selector?('[data-controller*="forms"]', wait: 1)
      debug_puts "Successfully signed in as #{user.email} on retry"
    end
  end

  def skip_2fa_and_sign_in(user)
    # The controller recognizes skip_2fa as a test bypass.
    if page.driver.is_a?(Capybara::RackTest::Driver)
      page.set_rack_session(skip_2fa: true)
    else
      # A synchronous request sets the bypass before sign-in.
      page.execute_script(<<~JS)
        try {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/test/set_session', false); // synchronous
          xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
          xhr.send('skip_2fa=true');
        } catch(e) { /* no-op */ }
      JS
    end
    system_test_sign_in(user)
  end

  def system_test_sign_out
    if page.has_link?('Sign Out', wait: 1)
      click_link 'Sign Out'
      wait_for_page_stable
      assert_current_path(sign_in_path, wait: 10)
    elsif page.has_button?('Sign Out', wait: 1)
      # Desktop and mobile navigation can expose duplicate Sign Out buttons.
      click_button 'Sign Out', match: :first
      wait_for_page_stable
      assert_current_path(sign_in_path, wait: 10)
    end
  rescue Ferrum::DeadBrowserError
    debug_puts 'Browser was already dead during sign-out. Continuing teardown.'
  rescue Ferrum::TimeoutError => e
    debug_puts "Timeout during sign-out: #{e.message}. Forcing browser restart."
    if page&.driver&.browser
      begin
        page.driver.browser.quit
      rescue StandardError
        # Session cleanup continues if browser shutdown fails.
      end
    end
  ensure
    # Clear test identity even if browser sign-out fails.
    clear_test_identity
    begin
      timeout_duration = 10 # seconds
      Timeout.timeout(timeout_duration) do
        Capybara.reset_sessions!
      end
    rescue Timeout::Error
      debug_puts 'Timeout during Capybara.reset_sessions!, forcing manual cleanup'
      begin
        page&.driver&.browser&.quit
      rescue StandardError
        # Session cleanup continues if browser shutdown fails.
      end
      Capybara.reset_sessions!
    rescue StandardError => e
      debug_puts "Error during session reset, continuing: #{e.message}"
    end
  end

  def _clear_pending_network_connections_ferrum
    return unless page&.driver&.browser

    page.driver.browser.cookies.clear
  rescue Ferrum::PendingConnectionsError => e
    debug_puts "Warning: Failed to clear pending connections: #{e.message}"
  rescue StandardError => e
    debug_puts "Warning: Failed to clear browser state: #{e.message}"
  end

  private

  # A redirect timeout falls back to a direct visit.
  def wait_for_redirect_or_visit(path, timeout: 15)
    assert_current_path(path, wait: timeout)
    debug_puts "Successfully redirected to #{current_path}"
  rescue Capybara::ExpectationNotMet
    debug_puts "Redirect to #{path} did not happen in time, manually navigating..."
    visit path
    wait_for_turbo
  end

  def debug_puts(msg)
    puts msg if ENV['VERBOSE_TESTS']
  end

  # Diagnostics must not interrupt authentication.

  def debug_authentication_state(_context, _user)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    begin
      if defined?(page) && page
        begin
          page.current_url

          page.has_text?('Sign In', wait: 0.5)
          page.has_text?('Sign Out', wait: 0.5)

          page.has_selector?('form[action="/sign_in"]', wait: 0.5)

          if page.driver.respond_to?(:browser) && page.driver.browser
            begin
              page.driver.browser.cookies.count
            rescue StandardError
              nil
            end
          end
        rescue StandardError
          # Continue with test identity diagnostics when page inspection fails.
        end
      end

      if defined?(Current)
        Current.user&.email || nil
        Current.test_user_id || nil
      end
    rescue StandardError
      # Diagnostic errors must not interrupt sign-in.
    end
  end

  def debug_authentication_corruption(_context, _error, _user)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    begin
      if defined?(page) && page
        begin
          page.current_url
        rescue StandardError
          nil
        end
        begin
          page.title
        rescue StandardError
          nil
        end
        begin
          page.body[0..200]
        rescue StandardError
          nil
        end
      end
    rescue StandardError
      # Run the browser probe even if page inspection fails.
    end

    begin
      page.evaluate_script('1+1') == 2 if page&.driver&.browser
    rescue StandardError
      # Browser probe errors must not interrupt authentication recovery.
    end
  end

  # Keep paths for supported roles aligned with ApplicationController#_dashboard_for.
  def user_dashboard_path(user)
    case user.type
    when 'Users::Administrator'
      admin_dashboard_path
    when 'Users::Constituent'
      constituent_portal_dashboard_path
    when 'Users::Evaluator'
      evaluators_dashboard_path
    when 'Users::Trainer'
      trainers_dashboard_path
    when 'Users::Vendor'
      vendor_portal_dashboard_path
    else
      root_path
    end
  end

  def dashboard_path_reached?(user, wait:)
    if user.type == 'Users::Administrator'
      page.has_current_path?(admin_dashboard_path, wait: wait) ||
        page.has_current_path?(admin_applications_path, wait: wait)
    else
      page.has_current_path?(user_dashboard_path(user), wait: wait)
    end
  end

  def assert_dashboard_landing!(user)
    if user.type == 'Users::Administrator'
      assert_admin_dashboard_landing!
      return
    end

    assert_current_path(user_dashboard_path(user), wait: 10)

    dashboard_heading = case user.type
                        when 'Users::Vendor'
                          'Vendor Dashboard'
                        else
                          'Dashboard'
                        end

    assert_selector('h1', text: dashboard_heading, wait: 10)
  end

  def assert_admin_dashboard_landing!
    assert(
      page.has_current_path?(admin_dashboard_path, wait: 10) ||
      page.has_current_path?(admin_applications_path, wait: 10),
      "expected current path to be #{admin_dashboard_path} or #{admin_applications_path}, got #{current_path}"
    )

    assert_selector('h1', text: /Applications|Admin Dashboard/, wait: 10)
  end

  def visit_with_retry(path, max_retries: 3, user: nil)
    success = false
    max_retries.times do |attempt|
      visit path
      assert_selector 'body', wait: 10
      success = true
      break
    rescue Ferrum::PendingConnectionsError => e
      debug_puts "Visit attempt #{attempt + 1}: Pending connections error: #{e.message}"
      if attempt < max_retries - 1
        debug_puts 'Retrying after clearing sessions...'
        clear_pending_network_connections
        assert_selector 'body', wait: 15
      else
        debug_puts "Failed after #{max_retries} attempts, continuing..."
      end
    rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError, Ferrum::TimeoutError => e
      debug_puts "Visit attempt #{attempt + 1}: Browser error: #{e.class} - #{e.message}"
      if attempt < max_retries - 1
        if respond_to?(:force_browser_restart, true)
          force_browser_restart('visit_with_retry')
        else
          Capybara.reset_sessions!
        end
        system_test_sign_in(user) if user && respond_to?(:system_test_sign_in)
      else
        debug_puts "Failed after #{max_retries} attempts due to browser errors."
      end
    end
    success
  end
end
