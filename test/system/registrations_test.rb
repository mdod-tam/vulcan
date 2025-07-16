# frozen_string_literal: true

require 'application_system_test_case'

class RegistrationsTest < ApplicationSystemTestCase
  test 'password visibility toggle changes field type and updates accessibility attributes' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Fill in the password fields using the warning-free method
    find_field('Password').set('password123')
    find_field('Confirm Password').set('password123')

    # Initially the password should be hidden (type="password")
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]

    # Find and click the toggle button for the password field (initial label)
    password_toggle = first("button[data-action='visibility#togglePassword']")
    password_toggle.click

    # The password should now be visible (type="text")
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'Hide password', password_toggle['aria-label']
    assert_equal 'true', password_toggle['aria-pressed']
    assert password_toggle[:class].include?('eye-open')

    # Click again to hide
    password_toggle.click

    # The password should be hidden again (type="password")
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'Show password', password_toggle['aria-label']
    assert_equal 'false', password_toggle['aria-pressed']
    assert password_toggle[:class].include?('eye-closed')
  end

  test 'password visibility automatically reverts after timeout' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Modify the timeout for testing purposes (using JavaScript)
    page.execute_script("document.querySelector('[data-visibility-timeout-value]').setAttribute('data-visibility-timeout-value', '2000')")

    # Fill in the password field
    find_field('Password').set('password123')

    # Click the toggle button
    find_field('Password').sibling("button[aria-label='Show password']").click

    # The password should be visible
    assert_equal 'text', find_field('Password')[:type]

    # Wait for the timeout
    sleep 2.5

    # The password should be hidden again
    assert_equal 'password', find_field('Password')[:type]
  end

  test 'password visibility toggle is keyboard accessible' do
    visit sign_up_path
    ensure_stimulus_loaded

    find_field('Password').set('password123')

    toggle_btn = first("button[data-action='visibility#togglePassword']")

    # Trigger click via JS to simulate keyboard activation (Enter/Space behaves as click on button)
    page.execute_script('arguments[0].click();', toggle_btn)

    assert_equal 'text', find_field('Password')[:type]

    page.execute_script('arguments[0].click();', toggle_btn)

    assert_equal 'password', find_field('Password')[:type]
  end

  test 'multiple password fields on the same page can be toggled independently' do
    visit sign_up_path
    ensure_stimulus_loaded

    # Fill in both password fields using the warning-free method
    find_field('Password').set('password123')
    find_field('Confirm Password').set('password123')

    # Toggle the first password field
    password_toggle = first("button[data-action='visibility#togglePassword']")
    password_toggle.click

    # Only the first password should be visible
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]

    # Toggle the second password field
    confirm_toggle = find_all("button[data-action='visibility#togglePassword']").last
    confirm_toggle.click

    # Both passwords should be visible
    assert_equal 'text', find_field('Password')[:type]
    assert_equal 'text', find_field('Confirm Password')[:type]

    # Toggle the first password field back
    password_toggle.click

    # Only the second password should be visible
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'text', find_field('Confirm Password')[:type]

    # Toggle the second password field back
    confirm_toggle.click

    # Both passwords should be hidden
    assert_equal 'password', find_field('Password')[:type]
    assert_equal 'password', find_field('Confirm Password')[:type]
  end
end
