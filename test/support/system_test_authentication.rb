# frozen_string_literal: true

require 'timeout'

# SystemTestAuthentication
#
# This module provides simplified authentication capabilities for system tests.
# It focuses on UI-based sign-in and sign-out with minimal error recovery logic.
module SystemTestAuthentication
  extend ActiveSupport::Concern
  include AuthenticationCore

  # Centralized browser rescue pattern that leverages existing infrastructure
  def with_browser_rescue(max_retries: 2)
    tries = 0
    begin
      yield
    rescue Ferrum::DeadBrowserError, Ferrum::BrowserError, Ferrum::NodeNotFoundError, Ferrum::TimeoutError => e
      raise if (tries += 1) > max_retries

      warn "🔄 #{e.class} - restarting browser session (attempt #{tries})"

      # Use existing force_browser_restart method if available
      if respond_to?(:force_browser_restart, true)
        force_browser_restart("authentication_rescue_#{tries}")
      else
        # Fallback to basic Capybara reset
        Capybara.reset_sessions!
        clear_pending_network_connections if respond_to?(:clear_pending_network_connections, true)
      end
      retry
    end
  end

  # Signs a user in through the UI.
  def system_test_sign_in(user, verify_path: nil)
    debug_authentication_state('SIGN_IN_START', user)

    # Visit sign-in page FIRST before checking authentication state
    # This ensures we're on a real page, not about:blank
    visit sign_in_path
    assert_selector('body', wait: 10)

    # NOW check if already authenticated (page has actual content)
    # Enhanced error handling for browser corruption detection
    begin
      if page.has_text?('Sign Out', wait: 1)
        debug_puts "Already signed in. Skipping sign-in for #{user.email}."
        debug_authentication_state('SIGN_IN_SKIP', user)
        return
      end
    rescue Ferrum::TimeoutError => e
      debug_authentication_corruption('SIGN_IN_CHECK_TIMEOUT', e, user)
      # Try to recover by forcing a fresh browser session
      force_browser_restart('sign_in_timeout_recovery') if respond_to?(:force_browser_restart)
      # Continue with sign-in after restart
    rescue StandardError => e
      debug_authentication_corruption('SIGN_IN_CHECK_ERROR', e, user)
      # Instead of raising, continue with sign-in attempt
      debug_puts "⚠️  Authentication state check failed (#{e.class}: #{e.message}) but browser appears responsive. " \
                 'This likely indicates a stale node reference or timing issue. Proceeding with fresh sign-in attempt ' \
                 "for #{user.email} after visiting #{sign_in_path}. Current URL: #{begin
                   page.current_url
                 rescue StandardError
                   'UNKNOWN'
                 end}"
    end

    # Clear any stored return_to path that could cause additional redirects
    if page.driver.is_a?(Capybara::RackTest::Driver)
      # RackTest – manipulate Rails session directly
      page.set_rack_session({})
    else
      # Real browser drivers – clear browser storage
      page.execute_script('sessionStorage.clear(); localStorage.clear();')
    end
    # Wait for the visibility controller on the sign-in form to be ready
    wait_for_stimulus_controller('visibility')

    # Set session variable to bypass 2FA for system tests
    if page.driver.is_a?(Capybara::RackTest::Driver)
      page.set_rack_session(skip_2fa: true)
    else
      # For Cuprite/browser tests, set session variable synchronously to avoid race conditions
      page.execute_script(<<~JS)
        try {
          var xhr = new XMLHttpRequest();
          xhr.open('POST', '/test/set_session', false); // synchronous
          xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
          xhr.send('skip_2fa=true');
        } catch(e) { /* no-op */ }
      JS
    end

    # Wait for form to be ready with more specific selectors
    assert_selector('form[action="/sign_in"]', wait: 10)

    within('form[action="/sign_in"]') do
      fill_in 'email-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    # Prefer native Capybara waiting for either redirect or form disappearance; do not refresh
    using_wait_time(10) do
      expected_dashboard_path = user_dashboard_path(user)
      page.has_current_path?(expected_dashboard_path, wait: 6) || has_no_selector?('form[action="/sign_in"]', wait: 6)
    end

    expected_dashboard_path = user_dashboard_path(user)

    using_wait_time(10) do # Give redirect more time to complete
      # Wait for EITHER successful redirect OR error message
      # This is better than checking current_path immediately
      # Try to wait for successful redirect to dashboard
      if page.has_current_path?(expected_dashboard_path, wait: 8)
        # Success! Continue to dashboard verification below
      elsif page.has_text?('Invalid email or password', wait: 2)
        # Clear authentication failure
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - invalid credentials detected."
      elsif page.has_css?('.flash-message, [role="alert"], .alert, .notice', wait: 2)
        # Check for any flash messages (success or error)
        flash_text = page.find('.flash-message, [role="alert"], .alert, .notice', wait: 1).text

        if flash_text.include?('Signed in successfully') || flash_text.include?('signed in')
          # Success message found, wait a bit more for redirect
          page.has_current_path?(expected_dashboard_path, wait: 5) # Wait for redirect
        else
          # Error message in flash
          take_screenshot
          raise "❌ Sign-in failed for #{user.email} - error in flash message: #{flash_text}"
        end
      elsif current_path == sign_in_path
        # Still on sign-in page after waiting, likely failed
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - still on sign-in page after waiting for redirect."
      end
    rescue Capybara::ElementNotFound => e
      # Final fallback - if we're on the expected dashboard, consider it success
      if current_path == expected_dashboard_path
        debug_puts 'Authentication successful despite Capybara timeout - on correct dashboard'
      else
        take_screenshot
        raise "❌ Sign-in failed for #{user.email} - timeout waiting for redirect. Current path: #{current_path}"
      end
    end

    # Handle different redirect scenarios based on verify_path
    if verify_path.present?
      # For 2FA flows, we expect to be redirected to verification page
      assert_current_path(verify_path, wait: 10)
      assert_selector('form', wait: 10)
      debug_puts "Successfully redirected to verification page for #{user.email}"
    elsif current_path&.match?(%r{/two_factor_authentication/verify})
      # Check if user has 2FA and we're on a verification page
      assert_selector('form', wait: 10)
      debug_puts "User #{user.email} has 2FA enabled, on verification page: #{current_path}"
    else
      # For normal sign-in, we expect to be redirected to dashboard
      expected_dashboard_path = user_dashboard_path(user)
      assert_current_path(expected_dashboard_path, wait: 10)

      # Check for appropriate dashboard heading based on user type
      dashboard_heading = case user.type
                          when 'Users::Administrator'
                            'Admin Dashboard'
                          when 'Users::Vendor'
                            'Vendor Dashboard'
                          else
                            'Dashboard'
                          end

      assert_selector('h1', text: dashboard_heading, wait: 10)
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
    # Retry once with fresh session
    debug_puts 'Retrying sign-in with fresh session...'
    Capybara.reset_sessions!
    clear_pending_network_connections

    # Retry the sign-in process once
    visit sign_in_path
    assert_selector('form[action="/sign_in"]', wait: 10)
    # Wait for the visibility controller on the sign-in form to be ready
    wait_for_stimulus_controller('visibility')

    within('form[action="/sign_in"]') do
      fill_in 'email-input', with: user.email
      fill_in 'password-input', with: 'password123'
      click_button 'Sign In'
    end

    # Wait for ALL redirects to complete on retry
    wait_for_page_stable(timeout: 15)
    wait_for_turbo(timeout: 10)

    # Apply same logic as main flow for retry
    if verify_path.present?
      assert_current_path(verify_path, wait: 10)
      assert_selector('form', wait: 10)
      debug_puts "Successfully redirected to verification page for #{user.email} on retry"
    elsif current_path&.match?(%r{/two_factor_authentication/verify})
      assert_selector('form', wait: 10)
      debug_puts "User #{user.email} has 2FA enabled, on verification page: #{current_path} on retry"
    else
      expected_dashboard_path = user_dashboard_path(user)
      assert_current_path(expected_dashboard_path, wait: 10)

      # Check for appropriate dashboard heading based on user type
      dashboard_heading = case user.type
                          when 'Users::Administrator'
                            'Admin Dashboard'
                          when 'Users::Vendor'
                            'Vendor Dashboard'
                          else
                            'Dashboard'
                          end

      assert_selector('h1', text: dashboard_heading, wait: 10)
      wait_for_stimulus_controller('forms') if has_selector?('[data-controller*="forms"]', wait: 1)
      debug_puts "Successfully signed in as #{user.email} on retry"
    end
  end

  def skip_2fa_and_sign_in(user)
    # Set a session variable to bypass 2FA. This requires controller cooperation.
    if page.driver.is_a?(Capybara::RackTest::Driver)
      page.set_rack_session(skip_2fa: true)
    else
      # For Cuprite/browser tests, set session variable synchronously to avoid race conditions
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

  # Signs the user out and resets the session state.
  def system_test_sign_out
    # Only try to sign out if a sign-out link/button is present.
    if page.has_link?('Sign Out', wait: 1)
      click_link 'Sign Out'
      wait_for_page_stable
      assert_current_path(sign_in_path, wait: 10)
    elsif page.has_button?('Sign Out', wait: 1)
      # Use match: :first to handle cases where multiple Sign Out buttons exist (desktop/mobile)
      click_button 'Sign Out', match: :first
      wait_for_page_stable
      assert_current_path(sign_in_path, wait: 10)
    end
  rescue Ferrum::DeadBrowserError
    # If the browser is already dead, we can't interact with it.
    debug_puts 'Browser was already dead during sign-out. Continuing teardown.'
  rescue Ferrum::TimeoutError => e
    # Handle timeout errors during sign-out gracefully
    debug_puts "Timeout during sign-out: #{e.message}. Forcing browser restart."
    # Force browser restart on timeout
    if page&.driver&.browser
      begin
        page.driver.browser.quit
      rescue StandardError
        # Ignore errors during forced quit
      end
    end
  ensure
    # Always clear identity and reset sessions to guarantee a clean state.
    clear_test_identity
    begin
      # Add timeout protection to the session reset
      timeout_duration = 10 # seconds
      Timeout.timeout(timeout_duration) do
        Capybara.reset_sessions!
      end
    rescue Timeout::Error
      debug_puts 'Timeout during Capybara.reset_sessions!, forcing manual cleanup'
      # Manual cleanup when reset_sessions! hangs
      begin
        page&.driver&.browser&.quit
      rescue StandardError
        # Ignore errors during manual cleanup
      end
      # Clear sessions using the public API
      Capybara.reset_sessions!
    rescue StandardError => e
      debug_puts "Error during session reset, continuing: #{e.message}"
    end
  end

  # Helper to clear pending network connections that can block tests.
  def _clear_pending_network_connections_ferrum
    return unless page&.driver&.browser

    # Clear cookies and try to reset network state
    page.driver.browser.cookies.clear
  rescue Ferrum::PendingConnectionsError => e
    # This is a known issue where Cuprite can't clear connections.
    # We'll log it and move on, as it's not always fatal.
    debug_puts "Warning: Failed to clear pending connections: #{e.message}"
  rescue StandardError => e
    debug_puts "Warning: Failed to clear browser state: #{e.message}"
  end

  private

  # Helper to wait for a redirect to a specific path, or visit it manually on timeout.
  # This uses a waiting assertion inside a rescue block to handle timeouts gracefully,
  # aligning with Capybara's best practices.
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

  # ============================================================================
  # AUTHENTICATION-SPECIFIC DEBUGGING SYSTEM
  # ============================================================================

  def debug_authentication_state(_context, _user)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    begin
      # Check current authentication state
      if defined?(page) && page
        begin
          page.current_url

          # Check for authentication indicators
          page.has_text?('Sign In', wait: 0.5)
          page.has_text?('Sign Out', wait: 0.5)

          # Check for common authentication elements
          page.has_selector?('form[action="/sign_in"]', wait: 0.5)

          # Check session/cookie state
          if page.driver.respond_to?(:browser) && page.driver.browser
            begin
              page.driver.browser.cookies.count
            rescue StandardError
              nil
            end
          end
        rescue StandardError
          # Silently handle page interaction errors
        end
      end

      # Check Current.user state
      if defined?(Current)
        Current.user&.email || nil
        Current.test_user_id || nil
      end
    rescue StandardError
      # Silently handle auth debug errors
    end
  end

  def debug_authentication_corruption(_context, _error, _user)
    return unless ENV['VERBOSE_TESTS'] || ENV['DEBUG_BROWSER']

    # Try to get additional context
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
      # Silently handle page context errors
    end

    # Check if browser is responsive at all
    begin
      page.evaluate_script('1+1') == 2 if page&.driver&.browser
    rescue StandardError
      # Silently handle browser ping errors
    end
  end

  # Determine the correct dashboard path based on user type
  # This must match the paths defined in ApplicationController#_dashboard_for
  def user_dashboard_path(user)
    case user.type
    when 'Users::Administrator'
      admin_applications_path # Match ApplicationController#_dashboard_for
    when 'Users::Constituent'
      constituent_portal_dashboard_path
    when 'Users::Evaluator'
      evaluators_dashboard_path
    when 'Users::Trainer'
      trainers_dashboard_path
    when 'Users::Vendor'
      vendor_portal_dashboard_path
    else
      # Default to root path if user type is unknown
      root_path
    end
  end

  # Visit method that handles pending connections gracefully
  def visit_with_retry(path, max_retries: 3, user: nil)
    success = false
    max_retries.times do |attempt|
      visit path
      assert_selector 'body', wait: 10
      success = true
      break # Success
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
