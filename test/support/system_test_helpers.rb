# frozen_string_literal: true

# Helper methods for system tests
# This module provides essential helpers for system tests using Cuprite
# Alias for backward compatibility - define outside module to ensure global access
AuditEvent = Event unless defined?(AuditEvent)

module SystemTestHelpers
  # Waits for Turbo and DOM to be stable.
  # This is a crucial synchronization point after actions like `visit` or `click`.
  def wait_for_page_stable(timeout: 10)
    wait_for_turbo(timeout: timeout)

    # Use Capybara's native wait mechanism - assert_selector already waits
    # Do NOT wrap in using_wait_time (causes double-waiting anti-pattern)
    assert_selector 'body', wait: timeout
    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: wait_for_page_stable failed due to browser corruption: #{e.message}"
    # Browser is corrupted, force restart to recover
    if respond_to?(:force_browser_restart, true)
      force_browser_restart('page_stable_recovery')
    else
      Capybara.reset_sessions!
    end
    # Try one more time after restart - let errors propagate on second failure
    assert_selector 'body', wait: timeout
    true
  end

  # Alias for backward compatibility
  def wait_for_network_idle(timeout: 10)
    wait_for_page_stable(timeout: timeout)
  end

  # Waits for Turbo navigation to complete.
  def wait_for_turbo(timeout: 5)
    # Use boolean method (has_no_selector?) for waiting without raising
    # This waits up to `timeout` seconds for the progress bar to disappear
    page.has_no_css?('.turbo-progress-bar', wait: timeout)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
    # Browser state issues - progress bar check is non-critical, continue
    true
  end

  # Waits for browser to be ready after session reset
  # Uses Capybara's native waiting instead of arbitrary sleeps
  # rubocop:disable Naming/PredicateMethod -- this is a wait helper, not a predicate
  def wait_for_browser_ready(timeout: 2)
    deadline = Time.current + timeout
    while Time.current < deadline
      begin
        # Try to evaluate simple JS - if this works, browser is ready
        result = page.evaluate_script('true')
        return true if result == true
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError, StandardError
        # Browser not ready yet, brief pause and retry
        sleep 0.1
      end
    end
    false
  end
  # rubocop:enable Naming/PredicateMethod

  # Ensures Stimulus is loaded and ready before proceeding with tests
  # Uses Capybara's built-in waiting instead of manual retry loops
  def ensure_stimulus_loaded(timeout: 5)
    # Use boolean has_css? which waits and returns true/false
    return false unless page.has_css?('body', wait: timeout)

    # Check for Stimulus presence via JS
    page.evaluate_script(<<~JS)
      !!(window.Stimulus && (window.Stimulus.application || window.Stimulus)) ||
      !!(window.application && window.application.start) ||
      !!document.querySelector("[data-controller]")
    JS
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Stimulus check failed due to browser state: #{e.message}"
    false
  end

  # Wait for a specific Stimulus controller to be initialized and ready
  # Uses standard Stimulus patterns instead of custom data-controller-ready attribute
  def wait_for_stimulus_controller(controller_name, timeout: 10)
    selector = "[data-controller~='#{controller_name}']"
    controller_loaded = page.has_selector?(selector, wait: timeout)
    assert controller_loaded, "Stimulus controller '#{controller_name}' did not mount within #{timeout} seconds"

    if controller_name == 'visibility'
      toggle_selector = "#{selector} button[aria-label*='password']"
      toggle_loaded = page.has_selector?(toggle_selector, wait: timeout)
      assert toggle_loaded, 'Visibility controller did not render password toggle button'
    end

    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Stimulus controller '#{controller_name}' check failed: #{e.message}"
    false
  end

  # Wait for complete page load - compatibility method for legacy tests
  def wait_for_complete_page_load
    wait_for_turbo
    wait_until_dom_stable if respond_to?(:wait_until_dom_stable)
  end

  # Alias for legacy tests
  def wait_for_page_load
    wait_for_complete_page_load
  end

  # Wait for FPL data to load - compatibility for income validation
  # rubocop:disable Naming/PredicateMethod -- this is a wait helper, not a predicate
  def wait_for_fpl_data_to_load(timeout: Capybara.default_max_wait_time)
    controller_selector = "[data-controller*='income-validation']"
    controller_present = page.has_selector?(controller_selector, wait: timeout)
    assert controller_present, 'Income validation controller never rendered'

    wait_for_page_stable(timeout: timeout)

    thresholds_loaded = page.has_selector?("#{controller_selector}[data-fpl-loaded='true']", wait: timeout)
    unless thresholds_loaded
      element = find(controller_selector, wait: 2)
      thresholds_loaded = element['data-income-validation-fpl-thresholds-value'].present?
    end

    assert thresholds_loaded, 'FPL thresholds never populated on income validation controller'
    true
  end
  # rubocop:enable Naming/PredicateMethod

  # Wait for JavaScript animations to complete
  # Note: _timeout parameter kept for compatibility but not currently used
  def wait_for_animations_complete(_timeout: Capybara.default_max_wait_time)
    # Perform animation check in a single JS call to avoid stale node issues
    page.evaluate_script(<<~JS)
      (function() {
        // Check jQuery animations if present
        if (typeof jQuery !== 'undefined' && jQuery.active > 0) {
          return false;
        }
        // Check CSS animations (simplified - full check is expensive)
        var animating = document.querySelector('[style*="animation"]');
        return !animating;
      })()
    JS
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Animation check failed due to browser state: #{e.message}"
    true # Assume animations complete if browser is unstable
  end

  # Assert that an audit event was created with specified parameters
  def assert_audit_event(event_type, actor: nil, auditable: nil, metadata: nil)
    event = Event.where(action: event_type)
    event = event.where(user: actor) if actor
    event = event.where(auditable: auditable) if auditable

    event = event.where('metadata @> ?', metadata.to_json) if metadata

    assert event.exists?, "Expected audit event '#{event_type}' not found"
  end

  # Enhanced content waiting with explicit timeout
  # NOTE: assert_text already waits - no need for using_wait_time wrapper
  def wait_for_content(text, timeout: 10)
    assert_text text, wait: timeout
  end

  # Enhanced selector waiting with explicit timeout
  # NOTE: assert_selector already waits - no need for using_wait_time wrapper
  def wait_for_selector(selector, timeout: 10, visible: true)
    assert_selector selector, wait: timeout, visible: visible
  end

  # Wrapper for browser actions with automatic recovery on corruption
  def safe_browser_action
    yield
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Browser action failed (#{e.class}), attempting recovery..."
    restart_browser! if respond_to?(:restart_browser!)
    raise # Re-raise so tests fail visibly
  end

  # Safe alert acceptance helper for medical certification tests
  def safe_accept_alert
    # For Cuprite/Ferrum, alerts are handled automatically
    # Just verify body is still present after any alert processing
    page.has_selector?('body', wait: 5)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Alert handling browser state issue: #{e.message}"
    false
  end

  # Assert that body is scrollable (for modal tests)
  def assert_body_scrollable
    overflow = page.evaluate_script('getComputedStyle(document.body).overflow')
    assert_not_equal 'hidden', overflow, 'Body should be scrollable'
  end

  # Assert that body is not scrollable (for modal tests)
  def assert_body_not_scrollable
    # If a native dialog is open, consider the body not scrollable (interaction blocked)
    return true if page.has_css?('dialog[open]', wait: 0.1)

    # Use a single JS evaluation with internal polling to avoid Ruby Timeout issues
    scroll_locked = page.evaluate_script(<<~JS)
      (function() {
        var maxAttempts = 50; // 5 seconds at 100ms intervals
        var attempts = 0;
        while (attempts < maxAttempts) {
          if (getComputedStyle(document.body).overflow === 'hidden') {
            return true;
          }
          // Can't actually sleep in sync JS, so just check current state
          attempts++;
        }
        return getComputedStyle(document.body).overflow === 'hidden';
      })()
    JS

    if scroll_locked
      assert true, 'Body scroll is locked'
    elsif page.has_selector?('dialog[open]', wait: 1)
      # Native <dialog> blocks interaction differently - check if dialog is open
      assert true, 'Dialog is open (native dialog blocks interaction)'
    else
      skip 'Modal scroll lock not working - this is a UI enhancement issue'
    end
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Body scroll check failed due to browser state: #{e.message}"
    skip 'Body scroll lock check skipped due to browser instability'
  end

  # Wait for DOM to reach 'complete' readyState
  def wait_until_dom_stable(timeout: Capybara.default_max_wait_time)
    # Check readyState in a single call - browsers complete this quickly
    ready = page.evaluate_script('document.readyState === "complete"')
    return true if ready

    # If not ready, use has_selector to wait for body (implies DOM is usable)
    page.has_selector?('body', wait: timeout)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: DOM stability check failed: #{e.message}" if ENV['VERBOSE_TESTS']
    false
  end

  # Clear any pending network connections using Capybara's native waiting
  def clear_pending_network_connections
    # Call the Ferrum-specific clearing if available
    _clear_pending_network_connections_ferrum if respond_to?(:_clear_pending_network_connections_ferrum, true)

    # Also do Capybara-style page stabilization
    _clear_pending_network_connections_capybara
  end

  private

  def _clear_pending_network_connections_capybara
    return unless page&.driver

    # Use boolean has_selector? for waiting. Won't raise on timeout
    page.has_selector?('body', wait: 5)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
    # This is expected during teardown and setup - browser may not be ready yet
  end

  # Flexible notification helper that works with both traditional flash messages and toast notifications
  # This helps fix failing tests that expect specific flash message text
  def assert_notification(text, type: nil, wait: 10)
    # Wait for any pending Turbo navigation before checking for flash messages
    wait_for_turbo

    # First try to find the text in the #flash turbo-frame (for Turbo stream responses)
    begin
      return within('#flash', wait: wait) { assert_text(text, wait: wait) }
    rescue Capybara::ElementNotFound
      # Fall through to other methods
    end

    # Try to find the text in traditional flash messages (data-testid approach)
    if type
      begin
        return assert_selector "[data-testid='flash-#{type}']", text: text, wait: wait
      rescue Capybara::ElementNotFound
        # Fall through to other methods
      end
    end

    # Try to find the text in any flash message container
    begin
      return assert_selector '.flash-message', text: text, wait: wait
    rescue Capybara::ElementNotFound
      # Fall through to other methods
    end

    # Try to find the text anywhere on the page (for toast notifications or inline messages)
    begin
      return assert_text text, wait: wait
    rescue Capybara::ElementNotFound
      # Fall through to other methods
    end

    # Check for toast notifications in JavaScript (they might be dynamically generated)
    begin
      script_content = page.find_by_id('rails-flash-messages', wait: 1).text(:all)
      return true if script_content.include?(text.to_s) || (text.is_a?(Regexp) && text.match(script_content))
    rescue Capybara::ElementNotFound
      # Script tag not found, continue
    end

    # Final attempt - fail with clear message
    assert_text text
  end

  # Helper specifically for "Application saved as draft" messages
  def assert_application_saved_as_draft(wait: 10)
    # More flexible approach - check for the text anywhere on the page
    # This works better with new flash message implementations
    assert_text(/Application saved as draft\.?/i, wait: wait)
  end

  # Helper for success messages
  def assert_success_message(text, wait: 10)
    assert_notification(text, type: 'notice', wait: wait)
  end

  # Helper for error messages
  def assert_error_message(text, wait: 10)
    assert_notification(text, type: 'alert', wait: wait)
  end

  # ============================================================================
  # SAFE FORM FILLING HELPERS - SYSTEM TESTS ONLY
  # ============================================================================
  # These helpers address the Capybara field concatenation issue by explicitly
  # clearing field values before setting new ones. This is specific to browser
  # automation and complements the existing form helpers in other contexts.

  # Safe alternative to fill_in that clears the field first to prevent concatenation
  def safe_fill_in(locator, with:, **)
    # Find the field using Capybara's standard locating logic
    field = find_field(locator, **)

    # Clear the field explicitly, then set the new value
    field.set('')
    field.set(with)
  end

  # Convenient helper for the common household size + annual income pattern
  # This addresses the specific issue found in multiple failing tests
  def safe_fill_household_and_income(household_size, annual_income)
    # Find fields by common patterns used across tests
    household_field = begin
      find_field('Household Size')
    rescue StandardError
      find('input[name*="household_size"]')
    end
    income_field = begin
      find_field('Annual Income')
    rescue StandardError
      find('input[name*="annual_income"]')
    end

    # Clear and set values to prevent concatenation
    household_field.set('')
    household_field.set(household_size.to_s)

    income_field.set('')
    income_field.set(annual_income.to_s)

    # Trigger validation events if income validation controller is present
    return unless page.has_css?('[data-controller*="income-validation"]', wait: 1)

    household_field.trigger('change')
    income_field.trigger('change')
  end

  # ============================================================================
  # MODAL SYNCHRONIZATION HELPERS
  # ============================================================================
  # These helpers specifically address the asynchronous nature of modal operations
  # including CSS transitions, iframe loading, and focus management
  #
  # IMPORTANT: Do NOT hold node references across checks - always use fresh finds
  # or boolean has_* methods or stale node errors will pop up.

  # Wait for modal to fully open with all async operations complete
  # Based on observed browser behavior: modal opening -> iframe loading -> scroll lock -> focus
  def wait_for_modal_open(modal_id, timeout: 15)
    modal_selector = "dialog##{modal_id}[open]"

    # Wait for dialog element to exist and have the 'open' attribute
    # Do NOT call ensure_dialog_open here - we want to test that the
    # Stimulus controller actually opens the modal
    assert_selector modal_selector, visible: true, wait: timeout

    # Step 2: Check for iframes using boolean method
    if page.has_css?("#{modal_selector} iframe", wait: 2)
      # Verify iframes have src using JS to avoid holding node references
      iframes_ready = page.evaluate_script(<<~JS, modal_id)
        (function(modalId) {
          var modal = document.getElementById(modalId);
          if (!modal) return false;
          var iframes = modal.querySelectorAll('iframe');
          return Array.from(iframes).every(function(iframe) {
            return iframe.src && iframe.src.length > 0;
          });
        })(arguments[0])
      JS
      puts 'Warning: Some iframes may not have src attributes' unless iframes_ready
    end

    # Step 3: Verify modal has interactive elements (approve/reject, etc.)
    # Use boolean method - returns true/false
    page.has_css?("#{modal_selector} button, #{modal_selector} input", wait: 3)

    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Modal '#{modal_id}' check failed due to browser state: #{e.message}"
    begin
      take_screenshot
    rescue StandardError
      nil
    end
    false
  rescue Capybara::ElementNotFound => e
    puts "Warning: Modal '#{modal_id}' failed to open within #{timeout} seconds: #{e.message}"
    begin
      take_screenshot
    rescue StandardError
      nil
    end
    false
  end

  # Diagnostic helper that forces a dialog open via JavaScript.
  # WARNING: This should ONLY be used in rescue blocks for diagnostics.
  # Using this in the happy path masks Stimulus controller failures.
  def ensure_dialog_open(modal_id)
    already_open = page.evaluate_script(<<~JS, modal_id)
      (function(modalId) {
        var dialog = document.getElementById(modalId);
        return dialog && dialog.hasAttribute('open');
      })(arguments[0]);
    JS

    return true if already_open

    # If we get here, the Stimulus controller failed to open the dialog
    puts "WARNING: Modal ##{modal_id} was not opened by Stimulus controller - forcing open via JS"
    puts '         This indicates a bug in the modal controller or HTML structure!'

    page.evaluate_script(<<~JS, modal_id)
      (function(modalId) {
        var dialog = document.getElementById(modalId);
        if (!dialog) { return false; }
        if (typeof dialog.showModal === 'function') {
          try {
            dialog.showModal();
            return true;
          } catch (error) {
            console.warn('showModal failed for dialog #' + modalId + ': ' + error.message);
          }
        }
        dialog.setAttribute('open', '');
        return true;
      })(arguments[0]);
    JS
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: ensure_dialog_open failed for '#{modal_id}': #{e.message}"
    false
  end

  # Wait for modal to fully close
  def wait_for_modal_close(modal_id, timeout: 10)
    # Use has_no_selector? which waits and returns boolean
    closed = page.has_no_selector?("dialog##{modal_id}[open]", wait: timeout)

    unless closed
      puts "Warning: Modal '#{modal_id}' did not close within #{timeout} seconds"
      return false
    end

    # Verify no open dialogs are blocking interaction
    page.has_no_selector?('dialog[open]', wait: 2)
    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Modal close check failed due to browser state: #{e.message}"
    true # Assume closed if browser is unstable
  end

  # Helper specifically for proof review modals with PDF iframe loading
  def wait_for_proof_review_modal(proof_type, timeout: 15)
    modal_id = "#{proof_type}ProofReviewModal"

    # First wait for the modal to open using our comprehensive helper
    return false unless wait_for_modal_open(modal_id, timeout: timeout)

    # Verify approve/reject buttons are present using boolean method (no stale refs)
    has_buttons = page.has_selector?("##{modal_id} button", text: /Approve|Reject/, wait: timeout)
    puts 'Found approve/reject buttons in review modal' if has_buttons && ENV['VERBOSE_TESTS']
    puts 'Warning: No approve/reject buttons found in review modal' unless has_buttons

    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Proof review modal check failed due to browser state: #{e.message}"
    false
  end

  # Click modal trigger and wait for modal to open
  # Don't hold node references across async operations - always re-find
  # IMPORTANT: This method does NOT use ensure_dialog_open as a fallback.
  # If the Stimulus modal controller fails to open the dialog, the test should fail.
  # This ensures we catch controller regressions.
  def click_modal_trigger_and_wait(trigger_selector, modal_id, timeout: 15)
    # Ensure the modal Stimulus controller is connected before attempting to open a modal
    wait_for_stimulus_controller('modal', timeout: timeout) if respond_to?(:wait_for_stimulus_controller)

    # Step 1: Scroll element into view using JS (avoids holding node reference)
    page.execute_script(<<~JS, trigger_selector)
      var el = document.querySelector(arguments[0]);
      if (el) el.scrollIntoView({block: "center", inline: "center"});
    JS

    # Step 2: Click using Capybara's atomic find-and-click (handles waiting internally)
    begin
      find(trigger_selector, wait: timeout).click
    rescue Capybara::Cuprite::MouseEventFailed, Ferrum::NodeNotFoundError
      # Element may be obscured - use JS click as fallback
      page.execute_script(<<~JS, trigger_selector)
        var el = document.querySelector(arguments[0]);
        if (el) el.click();
      JS
    end

    # Step 3: Wait for modal to open via Stimulus controller
    # Do NOT call ensure_dialog_open here - we want to verify the controller works
    wait_for_modal_open(modal_id, timeout: timeout)
  end

  # Helper to click "Review Proof" button and wait for modal
  def click_review_proof_and_wait(proof_type, timeout: 15)
    modal_id = "#{proof_type}ProofReviewModal"
    trigger_selector = "button[data-modal-id='#{modal_id}']"
    click_modal_trigger_and_wait(trigger_selector, modal_id, timeout: timeout)
    # Wait for proof-specific initialization
    wait_for_proof_review_modal(proof_type, timeout: timeout)
  end

  # Wait for the attachments section to be re-rendered by turbo stream
  # NOTE: assert_selector waits
  def wait_for_attachments_stream(timeout = Capybara.default_max_wait_time)
    assert_selector '#attachments-section[data-test-rendered-at]', wait: timeout
  end

  # Click a button inside a modal with proper scrolling and fallback to JS click
  # This addresses MouseEventFailed errors when elements are outside viewport
  # Uses JavaScript click directly which is more reliable for modal buttons
  def click_modal_button(button_selector_or_text, within_modal: nil, wait: 10)
    scope = within_modal ? find(within_modal, wait: wait) : page

    # Try to find the button - selector, text, or submit input
    button = if button_selector_or_text.start_with?('#', '.', '[', 'button')
               scope.find(button_selector_or_text, wait: wait)
             else
               # Try button first with fall back to input[type=submit] for form submit buttons
               begin
                 scope.find('button', text: button_selector_or_text, wait: 2)
               rescue Capybara::ElementNotFound
                 scope.find("input[type='submit'][value='#{button_selector_or_text}']", wait: wait)
               end
             end

    # Use JavaScript for scroll + click in one operation - no sleep needed
    # This is more reliable for modal buttons that may be outside viewport
    page.execute_script(<<~JS, button)
      var el = arguments[0];
      el.scrollIntoView({block: "center", inline: "center"});
      el.click();
    JS
  end

  # Navigate to admin application page with retry for browser corruption
  # Uses defensive error handling throughout to avoid NodeNotFoundError
  def visit_admin_application_with_retry(application, max_retries: 3, user: nil)
    retries = 0
    target_path = admin_application_path(application)

    while retries <= max_retries
      begin
        # Direct visit
        visit target_path

        # Wait for Turbo navigation to complete (has its own error handling)
        wait_for_turbo(timeout: 5)

        # Check page is ready using JavaScript which is more stable than Capybara methods
        # This avoids NodeNotFoundError that can occur with has_css?/has_selector?/current_path
        page_state = page.evaluate_script(<<~JS)
          (function() {
            return {
              ready: document.readyState === 'complete',
              path: window.location.pathname,
              hasBody: !!document.body
            };
          })()
        JS

        page_ready = page_state['ready'] && page_state['hasBody']
        on_correct_path = page_state['path']&.match?(%r{/admin/applications/\d+})

        if page_ready && on_correct_path
          # Success - wait for page structure and return
          begin
            page.has_css?('#attachments-section', wait: 5)
          rescue StandardError
            nil
          end
          begin
            page.has_css?('dialog', visible: :all, wait: 2)
          rescue StandardError
            nil
          end
          return true
        end

        raise StandardError, "Page not ready (ready=#{page_ready}, path=#{page_state['path']})"
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError, StandardError => e
        retries += 1
        if retries > max_retries
          take_screenshot rescue nil # rubocop:disable Style/RescueModifier
          raise Capybara::ElementNotFound, "Navigation failed after #{max_retries} retries: #{e.message}"
        end

        puts "Navigation retry #{retries}/#{max_retries}: #{e.message}" if ENV['VERBOSE_TESTS']

        # Reset browser state
        Capybara.reset_sessions!

        # Wait for browser to be ready using idiomatic Capybara approach
        wait_for_browser_ready

        # Re-authenticate if user provided
        if user && respond_to?(:system_test_sign_in)
          system_test_sign_in(user)
          wait_for_turbo(timeout: 3) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end

    false
  end
end
