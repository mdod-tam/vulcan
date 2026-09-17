# frozen_string_literal: true

require 'application_system_test_case'

module Harness
  class RuntimeJsEvidenceTest < ApplicationSystemTestCase
    setup do
      visit sign_in_path
      assert_selector 'form'
    end

    test 'Cuprite fails for uncaught exceptions and Stimulus errors' do
      assert_equal true, page.driver.options[:js_errors]
      [
        'setTimeout(() => { throw new Error("uncaught probe"); }, 0)',
        'window.Stimulus.handleError(new Error("controller probe"), "Error connecting controller", {})',
        'setTimeout(() => { Promise.reject(new Error("rejection probe")); }, 0)'
      ].each do |script|
        assert_raises(Ferrum::JavaScriptError, script) do
          page.execute_script(<<~JS, script)
            const probe = document.createElement('script');
            probe.textContent = arguments[0];
            document.body.appendChild(probe);
          JS
          wait_until(time: 5) { page.evaluate_script('false') }
        end
      end
    end

    test 'runtime errors and a missing controller invalidate screenshot evidence' do
      page.execute_script(<<~JS)
        const orphan = document.createElement("div");
        orphan.dataset.controller = "unregistered-probe";
        document.body.appendChild(orphan);
      JS
      reasons = screenshot_unusable_reasons(
        { url: current_url, meaningful_match_count: 1, body_text_length: 100 },
        { solid_color: false }, stimulus: screenshot_stimulus_state, js_errors: ['controller failed']
      )
      assert_includes reasons, 'controllers_not_connected'
      assert_includes reasons, 'runtime_errors'
    end
  end
end
