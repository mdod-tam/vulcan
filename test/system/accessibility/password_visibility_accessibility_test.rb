# frozen_string_literal: true

require 'application_system_test_case'

module Accessibility
  class PasswordVisibilityAccessibilityTest < ApplicationSystemTestCase
    test 'password toggle updates its label and aria-pressed state' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      password_toggles = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\").length")
      assert_equal 2, password_toggles, 'Should have 2 password toggle buttons (password and confirmation)'

      initial_aria_pressed = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].getAttribute('aria-pressed')")
      assert_equal 'false', initial_aria_pressed

      # Use a DOM click to bypass Capybara visibility restrictions.
      page.execute_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].click()")

      hide_buttons = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Hide password']\").length")
      assert_equal 1, hide_buttons, "Should have 1 'Hide password' button after clicking"

      updated_aria_pressed = page.evaluate_script("document.querySelector(\"button[aria-label='Hide password']\").getAttribute('aria-pressed')")
      assert_equal 'true', updated_aria_pressed

      page.execute_script("document.querySelector(\"button[aria-label='Hide password']\").click()")

      final_show_buttons = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\").length")
      assert_equal 2, final_show_buttons, "Should be back to 2 'Show password' buttons"
    end

    test 'password fields have IDs and reference visibility status in separate containers' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      password_field_count = page.evaluate_script("document.querySelectorAll(\"input[type='password']\").length")
      assert_equal 2, password_field_count, 'Should have 2 password fields'

      first_field_has_id = page.evaluate_script("!!document.querySelectorAll(\"input[type='password']\")[0].id")
      second_field_has_id = page.evaluate_script("!!document.querySelectorAll(\"input[type='password']\")[1].id")
      assert first_field_has_id, 'First password field should have an ID'
      assert second_field_has_id, 'Second password field should have an ID'

      first_field_aria = page.evaluate_script("document.querySelectorAll(\"input[type='password']\")[0].getAttribute('aria-describedby')")
      second_field_aria = page.evaluate_script("document.querySelectorAll(\"input[type='password']\")[1].getAttribute('aria-describedby')")
      assert first_field_aria&.include?('password-visibility-status'), 'First password field should reference visibility status'
      assert second_field_aria&.include?('password-visibility-status'), 'Second password field should reference visibility status'

      container_count = page.evaluate_script("document.querySelectorAll(\"div[data-controller='visibility']\").length")
      assert_equal 2, container_count, 'Should have 2 containers with visibility controllers'
    end

    test 'password toggle buttons have SVG icons and the first has hover and focus classes' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      first_button_has_svg = page.evaluate_script("!!document.querySelectorAll(\"button[aria-label='Show password']\")[0].querySelector('svg')")
      second_button_has_svg = page.evaluate_script("!!document.querySelectorAll(\"button[aria-label='Show password']\")[1].querySelector('svg')")
      assert first_button_has_svg, 'First password toggle button should have SVG icon'
      assert second_button_has_svg, 'Second password toggle button should have SVG icon'

      first_button_has_hover = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].className.includes('hover:')")
      first_button_has_focus = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].className.includes('focus:')")
      assert first_button_has_hover, 'First button should have hover styling classes'
      assert first_button_has_focus, 'First button should have focus styling classes'
    end

    test 'password toggle buttons measure at least 24 by 24 CSS pixels' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      first_button_width = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].getBoundingClientRect().width")
      first_button_height = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].getBoundingClientRect().height")
      assert first_button_width >= 24, "First button width should be at least 24px, got #{first_button_width}"
      assert first_button_height >= 24, "First button height should be at least 24px, got #{first_button_height}"

      second_button_width = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[1].getBoundingClientRect().width")
      second_button_height = page.evaluate_script("document.querySelectorAll(\"button[aria-label='Show password']\")[1].getBoundingClientRect().height")
      assert second_button_width >= 24, "Second button width should be at least 24px, got #{second_button_width}"
      assert second_button_height >= 24, "Second button height should be at least 24px, got #{second_button_height}"
    end

    test 'password toggle buttons accept DOM focus and expose click methods' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      page.execute_script("document.querySelectorAll(\"button[aria-label='Show password']\")[0].focus()")
      first_button_focused = page.evaluate_script("document.activeElement === document.querySelectorAll(\"button[aria-label='Show password']\")[0]")
      assert first_button_focused, 'First button should be focusable and become the active element'

      page.execute_script("document.querySelectorAll(\"button[aria-label='Show password']\")[1].focus()")
      second_button_focused = page.evaluate_script("document.activeElement === document.querySelectorAll(\"button[aria-label='Show password']\")[1]")
      assert second_button_focused, 'Second button should be focusable and become the active element'

      first_button_clickable = page.evaluate_script("typeof document.querySelectorAll(\"button[aria-label='Show password']\")[0].click === 'function'")
      second_button_clickable = page.evaluate_script("typeof document.querySelectorAll(\"button[aria-label='Show password']\")[1].click === 'function'")
      assert first_button_clickable, 'First button should expose a click method'
      assert second_button_clickable, 'Second button should expose a click method'
    end

    test 'DOM activation applies eye-open and removes eye-closed' do
      visit sign_up_path

      wait_for_stimulus_controller('visibility')

      page.execute_script("document.querySelector(\"button[aria-label='Show password']\").click()")

      post_click_has_eye_open = page.evaluate_script("document.querySelector(\"button[aria-label='Hide password']\").classList.contains('eye-open')")
      post_click_has_eye_closed = page.evaluate_script("document.querySelector(\"button[aria-label='Hide password']\").classList.contains('eye-closed')")

      assert post_click_has_eye_open, "Button should have 'eye-open' class when password is visible"
      assert_not post_click_has_eye_closed, "Button should not have 'eye-closed' class when password is visible"
    end
  end
end
