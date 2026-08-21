# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Harness
  # The screenshot sidecar asserts "no JavaScript errors, and every declared controller connected".
  # Nothing else in the suite checks that the harness making that claim can actually detect a
  # failure, so a silently broken collector would report a clean page forever -- which is worse than
  # not collecting at all, because it reads as proof.
  #
  # These drive each channel directly rather than through a deliberately broken controller: a real
  # broken controller would have to be registered in the production bundle to be reachable here.
  class RuntimeJsEvidenceTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      visit sign_in_path
      assert_selector 'form'
    end

    test 'the collector is installed before the page runs its own scripts' do
      assert page.evaluate_script('!!window.__runtimeJs'), 'collector missing on a freshly visited page'
      assert_empty collected_errors
    end

    # Each of these reaches the collector by a different mechanism. A collector that only listens for
    # the error event -- which is what the obvious implementation does -- catches exactly one of them.
    test 'every error channel is captured' do
      page.execute_script(<<~JS)
        window.dispatchEvent(new ErrorEvent("error", { message: "probe-error-event" }));
        console.error("probe-console-error");
      JS

      # Stimulus reports a controller that threw on connect by *calling* window.onerror as a plain
      # function. That never dispatches an error event, so this is the channel that decides whether
      # a broken controller is visible at all.
      page.execute_script('window.onerror("probe-stimulus-onerror", "app.js", 1, 1, new Error("probe"))')

      # Deferred out of the evaluated expression on purpose: CDP awaits the result of what it
      # evaluates, which counts as handling the promise, so a bare `Promise.reject(...)` here is
      # never unhandled and proves nothing. A rejection from application code -- a controller's
      # fetch, say -- has no such handler, which is the case this channel exists for.
      page.execute_script('setTimeout(function () { Promise.reject(new Error("probe-rejection")); }, 0)')
      # Reported on a later task, so let it settle rather than racing it.
      assert_runtime_js_error(/probe-rejection/)

      messages = collected_errors.pluck('message').join(' | ')
      assert_match(/probe-error-event/, messages)
      assert_match(/probe-console-error/, messages)
      assert_match(/probe-stimulus-onerror/, messages)

      channels = collected_errors.flat_map { |error| error['channels'] }.uniq
      assert_includes channels, 'error-event'
      assert_includes channels, 'console.error'
      assert_includes channels, 'window.onerror'
      # Note the channel: headless Chrome under Cuprite never fires `unhandledrejection` in the page,
      # so the rejection is caught by Chrome's own Runtime.exceptionThrown instead. The in-page
      # listener is kept for real browsers, but this is what actually covers rejections here.
      assert_includes channels, 'cdp-exception'
    end

    # One entry per distinct message: a genuine uncaught exception legitimately arrives on both the
    # error event and window.onerror, and reporting it twice would make every real failure look like
    # two.
    test 'the same message seen on two channels is one finding' do
      page.execute_script(<<~JS)
        window.dispatchEvent(new ErrorEvent("error", { message: "probe-duplicate" }));
        window.onerror("probe-duplicate", "app.js", 1, 1, new Error("probe-duplicate"));
      JS

      matching = collected_errors.select { |error| error['message'] == 'probe-duplicate' }
      assert_equal 1, matching.size, "expected one entry, got #{matching.inspect}"
      assert_equal %w[error-event window.onerror], matching.first['channels'].sort
    end

    # The whole point of recording `declared` separately from `connected`: a controller the page
    # asked for and did not get is invisible in a list of what connected.
    test 'a declared controller that never connects is reported' do
      page.execute_script(<<~JS)
        const orphan = document.createElement("div");
        orphan.setAttribute("data-controller", "not-a-registered-controller");
        document.body.appendChild(orphan);
      JS

      assert_includes stimulus_state['declared'], 'not-a-registered-controller'
      assert_not_includes stimulus_state['connected'], 'not-a-registered-controller'
      assert_includes stimulus_state['declared_not_connected'], 'not-a-registered-controller'
    end

    test 'the router is genuinely read rather than silently swallowed' do
      assert stimulus_state['router_read'], 'the Stimulus router could not be read at all'
    end

    private

    # Deliberately the merged view the sidecar records, not the raw in-page array: the sidecar is
    # what the evidence contract is about, and the two sources are only useful once combined.
    def collected_errors
      Array(screenshot_js_errors)
    end

    def stimulus_state
      screenshot_stimulus_state
    end

    def assert_runtime_js_error(pattern, timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if collected_errors.any? { |error| error['message'].to_s.match?(pattern) }
        raise Minitest::Assertion, "no collected error matched #{pattern.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
    end
  end
end
