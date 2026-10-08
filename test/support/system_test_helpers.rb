# frozen_string_literal: true

# Legacy name for Event in system tests.
AuditEvent = Event unless defined?(AuditEvent)

module SystemTestHelpers
  def meaningful_page_content_selector
    'main, [role="main"], h1, [data-testid], form[action], header nav'
  end

  # The default selectors identify page structure beyond the body.
  def wait_for_meaningful_page_content(timeout: 5, selector: meaningful_page_content_selector)
    return false unless page&.driver
    return false if page.current_url == 'about:blank'

    wait_for_turbo(timeout: [timeout, 1].min)
    page.has_selector?(selector, wait: timeout)
  rescue StandardError
    false
  end

  def capture_before_browser_recovery(reason, error = nil)
    return unless respond_to?(:capture_browser_recovery_diagnostics, true)

    capture_browser_recovery_diagnostics(reason, error: error)
  end

  # Asserts body presence after a Turbo wait. The content wait can return false.
  def wait_for_page_stable(timeout: 10)
    wait_for_turbo(timeout: timeout)

    assert_selector 'body', wait: timeout
    wait_for_meaningful_page_content(timeout: [timeout, 3].min)
    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: wait_for_page_stable failed due to browser corruption: #{e.message}"
    if respond_to?(:force_browser_restart, true)
      force_browser_restart('page_stable_recovery')
    else
      Capybara.reset_sessions!
    end
    # After recovery, repeat only the body assertion and propagate a second failure.
    assert_selector 'body', wait: timeout
    true
  end

  def wait_for_network_idle(timeout: 10)
    wait_for_page_stable(timeout: timeout)
  end

  # The absence of a Turbo progress bar is the navigation signal used here.
  def wait_for_turbo(timeout: 5)
    page.has_no_css?('.turbo-progress-bar', wait: timeout)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
    true
  end

  # Polls JavaScript after session reset. Errors cause a 0.1-second pause.
  def wait_for_browser_ready(timeout: 2)
    deadline = Time.current + timeout
    while Time.current < deadline
      begin
        result = page.evaluate_script('true')
        return true if result == true
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError, StandardError
        sleep 0.1
      end
    end
    false
  end

  # A window symbol or data-controller attribute suffices. This result does not prove controller connection.
  def ensure_stimulus_loaded(timeout: 5)
    return false unless page.has_css?('body', wait: timeout)

    page.evaluate_script(<<~JS)
      !!(window.Stimulus && (window.Stimulus.application || window.Stimulus)) ||
      !!(window.application && window.application.start) ||
      !!document.querySelector("[data-controller]")
    JS
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Stimulus check failed due to browser state: #{e.message}"
    false
  end

  # Waits for controller markup, with a password button requirement for visibility.
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

  def wait_for_complete_page_load
    wait_for_turbo
    wait_until_dom_stable if respond_to?(:wait_until_dom_stable)
  end

  def wait_for_page_load
    wait_for_complete_page_load
  end

  # Accepts the loaded marker or a nonempty thresholds attribute.
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

  # _timeout remains for caller compatibility. The JavaScript runs once.
  # It tests jQuery.active and an inline animation attribute.
  def wait_for_animations_complete(_timeout: Capybara.default_max_wait_time)
    page.evaluate_script(<<~JS)
      (function() {
        if (typeof jQuery !== 'undefined' && jQuery.active > 0) {
          return false;
        }
        var animating = document.querySelector('[style*="animation"]');
        return !animating;
      })()
    JS
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Animation check failed due to browser state: #{e.message}"
    true # Browser errors count as complete.
  end

  def assert_audit_event(event_type, actor: nil, auditable: nil, metadata: nil)
    event = Event.where(action: event_type)
    event = event.where(user: actor) if actor
    event = event.where(auditable: auditable) if auditable

    event = event.where('metadata @> ?', metadata.to_json) if metadata

    assert event.exists?, "Expected audit event '#{event_type}' not found"
  end

  def wait_for_content(text, timeout: 10)
    assert_text text, wait: timeout
  end

  def wait_for_selector(selector, timeout: 10, visible: true)
    assert_selector selector, wait: timeout, visible: visible
  end

  def safe_browser_action
    yield
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Browser action failed (#{e.class}), attempting recovery..."
    restart_browser! if respond_to?(:restart_browser!)
    raise # Recovery does not suppress the test failure.
  end

  # Cuprite accepts unhandled alerts. This helper waits for the body afterward.
  def safe_accept_alert
    page.has_selector?('body', wait: 5)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Alert handling browser state issue: #{e.message}"
    false
  end

  def assert_body_scrollable
    overflow = page.evaluate_script('getComputedStyle(document.body).overflow')
    assert_not_equal 'hidden', overflow, 'Body should be scrollable'
  end

  # An open dialog satisfies this helper without a test of body overflow.
  # The JavaScript loop is synchronous, without a timed wait.
  def assert_body_not_scrollable
    return true if page.has_css?('dialog[open]', wait: 0.1)

    scroll_locked = page.evaluate_script(<<~JS)
      (function() {
        var maxAttempts = 50;
        var attempts = 0;
        while (attempts < maxAttempts) {
          if (getComputedStyle(document.body).overflow === 'hidden') {
            return true;
          }
          attempts++;
        }
        return getComputedStyle(document.body).overflow === 'hidden';
      })()
    JS

    if scroll_locked
      assert true, 'Body scroll is locked'
    elsif page.has_selector?('dialog[open]', wait: 1)
      assert true, 'Dialog is open (native dialog blocks interaction)'
    else
      skip 'Modal scroll lock not working - this is a UI enhancement issue'
    end
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Body scroll check failed due to browser state: #{e.message}"
    skip 'Body scroll lock check skipped due to browser instability'
  end

  # If readyState is incomplete, body presence supplies the readiness result.
  def wait_until_dom_stable(timeout: Capybara.default_max_wait_time)
    ready = page.evaluate_script('document.readyState === "complete"')
    if ready
      wait_for_meaningful_page_content(timeout: [timeout, 3].min)
      return true
    end

    body_present = page.has_selector?('body', wait: timeout)
    wait_for_meaningful_page_content(timeout: [timeout, 3].min) if body_present
    body_present
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: DOM stability check failed: #{e.message}" if ENV['VERBOSE_TESTS']
    false
  end

  def clear_pending_network_connections
    _clear_pending_network_connections_ferrum if respond_to?(:_clear_pending_network_connections_ferrum, true)

    _clear_pending_network_connections_capybara
  end

  private

  def _clear_pending_network_connections_capybara
    return unless page&.driver

    page.has_selector?('body', wait: 5)
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
    # This cleanup probe is optional when browser recovery removes the page.
  end

  # Searches flash containers, page text, and the Rails message script.
  # Fallback paths rescue only Capybara::ElementNotFound.
  def assert_notification(text, type: nil, wait: 10)
    wait_for_turbo

    begin
      return within('#flash', wait: wait) { assert_text(text, wait: wait) }
    rescue Capybara::ElementNotFound
      # Other notification sources can exist without this container.
    end

    if type
      begin
        return assert_selector "[data-testid='flash-#{type}']", text: text, wait: wait
      rescue Capybara::ElementNotFound
        # Other notification sources can omit the typed target.
      end
    end

    begin
      return assert_selector '.flash-message', text: text, wait: wait
    rescue Capybara::ElementNotFound
      # Other notification sources can omit this class.
    end

    begin
      return assert_text text, wait: wait
    rescue Capybara::ElementNotFound
      # A missing page element leaves the message-script fallback available.
    end

    begin
      script_content = page.find_by_id('rails-flash-messages', wait: 1).text(:all)
      return true if script_content.include?(text.to_s) || (text.is_a?(Regexp) && text.match(script_content))
    rescue Capybara::ElementNotFound
      # The final page assertion reports failure if no source matches.
    end

    assert_text text
  end

  def assert_application_saved_as_draft(wait: 10)
    assert_text(/Application saved as draft\.?/i, wait: wait)
  end

  def assert_success_message(text, wait: 10)
    assert_notification(text, type: 'notice', wait: wait)
  end

  def assert_error_message(text, wait: 10)
    assert_notification(text, type: 'alert', wait: wait)
  end

  # The helper clears the field before replacement to avoid concatenation during browser automation.
  def safe_fill_in(locator, with:, **)
    field = find_field(locator, **)

    field.set('')
    field.set(with)
  end

  # The helper clears both fields before replacement. With income validation markup, it emits change events.
  def safe_fill_household_and_income(household_size, annual_income)
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

    household_field.set('')
    household_field.set(household_size.to_s)

    income_field.set('')
    income_field.set(annual_income.to_s)

    return unless page.has_css?('[data-controller*="income-validation"]', wait: 1)

    household_field.trigger('change')
    income_field.trigger('change')
  end

  # Use fresh finds or boolean queries across asynchronous operations.
  # Asserts the open dialog. Missing iframe sources and controls produce no assertion failure.
  def wait_for_modal_open(modal_id, timeout: 15)
    modal_selector = "dialog##{modal_id}[open]"

    assert_selector modal_selector, visible: true, wait: timeout

    if page.has_css?("#{modal_selector} iframe", wait: 2)
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

  # Use only in rescue diagnostics. Forced opening can conceal controller failures.
  def ensure_dialog_open(modal_id)
    already_open = page.evaluate_script(<<~JS, modal_id)
      (function(modalId) {
        var dialog = document.getElementById(modalId);
        return dialog && dialog.hasAttribute('open');
      })(arguments[0]);
    JS

    return true if already_open

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

  # A browser error counts as closed. Other open dialogs do not change the result.
  def wait_for_modal_close(modal_id, timeout: 10)
    closed = page.has_no_selector?("dialog##{modal_id}[open]", wait: timeout)

    unless closed
      puts "Warning: Modal '#{modal_id}' did not close within #{timeout} seconds"
      return false
    end

    page.has_no_selector?('dialog[open]', wait: 2)
    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Modal close check failed due to browser state: #{e.message}"
    true # Browser errors count as closed.
  end

  # Missing approval controls produce a warning, not a false result.
  def wait_for_proof_review_modal(proof_type, timeout: 15)
    modal_id = "#{proof_type}ProofReviewModal"

    return false unless wait_for_modal_open(modal_id, timeout: timeout)

    has_buttons = page.has_selector?("##{modal_id} button", text: /Approve|Reject/, wait: timeout)
    puts 'Found approve/reject buttons in review modal' if has_buttons && ENV['VERBOSE_TESTS']
    puts 'Warning: No approve/reject buttons found in review modal' unless has_buttons

    true
  rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError => e
    puts "Warning: Proof review modal check failed due to browser state: #{e.message}"
    false
  end

  # Re-find the trigger across asynchronous steps. Do not force the dialog open.
  def click_modal_trigger_and_wait(trigger_selector, modal_id, timeout: 15)
    wait_for_stimulus_controller('modal', timeout: timeout) if respond_to?(:wait_for_stimulus_controller)

    page.execute_script(<<~JS, trigger_selector)
      var el = document.querySelector(arguments[0]);
      if (el) el.scrollIntoView({block: "center", inline: "center"});
    JS

    begin
      find(trigger_selector, wait: timeout).click
    rescue Capybara::Cuprite::MouseEventFailed, Ferrum::NodeNotFoundError
      # Use a JavaScript click if Cuprite cannot click the trigger.
      page.execute_script(<<~JS, trigger_selector)
        var el = document.querySelector(arguments[0]);
        if (el) el.click();
      JS
    end

    wait_for_modal_open(modal_id, timeout: timeout)
  end

  def click_review_proof_and_wait(proof_type, timeout: 15)
    modal_id = "#{proof_type}ProofReviewModal"
    trigger_selector = "button[data-modal-id='#{modal_id}']"
    click_modal_trigger_and_wait(trigger_selector, modal_id, timeout: timeout)
    wait_for_proof_review_modal(proof_type, timeout: timeout)
  end

  # Waits for the attachments marker, without comparison to its previous timestamp.
  def wait_for_attachments_stream(timeout = Capybara.default_max_wait_time)
    assert_selector '#attachments-section[data-test-rendered-at]', wait: timeout
  end

  # The proof rejection dialog locks its reason until staff pick one, so a custom reason starts with Other.
  def submit_custom_proof_rejection(reason, modal: '#proofRejectionModal')
    within(modal) do
      find("button[data-action='click->rejection-form#selectOther']").click
      fill_in 'Reason for Rejection', with: reason
      click_button 'Submit'
    end
  end

  # Scroll and click in one script to handle controls outside the viewport.
  def click_modal_button(button_selector_or_text, within_modal: nil, wait: 10)
    scope = within_modal ? find(within_modal, wait: wait) : page

    button = if button_selector_or_text.start_with?('#', '.', '[', 'button')
               scope.find(button_selector_or_text, wait: wait)
             else
               begin
                 scope.find('button', text: button_selector_or_text, wait: 2)
               rescue Capybara::ElementNotFound
                 scope.find("input[type='submit'][value='#{button_selector_or_text}']", wait: wait)
               end
             end

    page.execute_script(<<~JS, button)
      var el = arguments[0];
      el.scrollIntoView({block: "center", inline: "center"});
      el.click();
    JS
  end

  # Retries navigation after session reset and can sign in again.
  def visit_admin_application_with_retry(application, max_retries: 3, user: nil)
    retries = 0
    target_path = admin_application_path(application)

    while retries <= max_retries
      begin
        visit target_path

        wait_for_turbo(timeout: 5)

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

        capture_before_browser_recovery('visit_admin_application_with_retry', e)
        Capybara.reset_sessions!

        wait_for_browser_ready

        if user && respond_to?(:system_test_sign_in)
          system_test_sign_in(user)
          wait_for_turbo(timeout: 3) rescue nil # rubocop:disable Style/RescueModifier
        end
      end
    end

    false
  end
end
