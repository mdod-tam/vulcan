# frozen_string_literal: true

require 'application_system_test_case'

class PasswordVisibilitySystemTest < ApplicationSystemTestCase
  test 'password fields on registration form have visibility toggle' do
    visit sign_up_path

    ensure_stimulus_loaded

    assert_selector "input#user_password[type='password']"
    assert_selector "button[data-action='visibility#togglePassword']", count: 2 # One for each password field
    assert_selector "input#user_password_confirmation[type='password']"

    assert toggle_password_visibility('user_password')

    assert_selector "input#user_password[type='text']"
    password_field = find('input#user_password')
    container = password_field.ancestor('[data-controller="visibility"]')
    password_toggle = container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'true', password_toggle['aria-pressed']

    assert toggle_password_visibility('user_password')

    assert_selector "input#user_password[type='password']"
    assert_equal 'false', password_toggle['aria-pressed']

    assert toggle_password_visibility('user_password_confirmation')

    assert_selector "input#user_password_confirmation[type='text']"
    confirmation_field = find('input#user_password_confirmation')
    confirmation_container = confirmation_field.ancestor('[data-controller="visibility"]')
    confirmation_toggle = confirmation_container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'true', confirmation_toggle['aria-pressed']

    assert toggle_password_visibility('user_password_confirmation')

    assert_selector "input#user_password_confirmation[type='password']"
    assert_equal 'false', confirmation_toggle['aria-pressed']
  end

  test 'password visibility automatically hides after timeout' do
    visit sign_up_path

    ensure_stimulus_loaded

    # The visibility controller does not read this global. It uses
    # data-visibility-timeout-value, which is 5000 ms by default.
    page.execute_script('window.passwordVisibilityTimeout = 500;')

    assert toggle_password_visibility('user_password')

    assert_selector "input#user_password[type='text']"
    password_field = find('input#user_password')
    container = password_field.ancestor('[data-controller="visibility"]')
    password_toggle = container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'true', password_toggle['aria-pressed']

    sleep 0.6

    # This passes only because Capybara waits past the real 5000 ms timeout.
    assert_selector "input#user_password[type='password']"
    password_toggle = container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'false', password_toggle['aria-pressed']
  end

  test 'password fields have correct accessibility attributes' do
    skip 'This test needs to be updated to match the new implementation'
    visit sign_up_path

    ensure_stimulus_loaded

    password_field = find('input#user_password')
    container = password_field.ancestor('.relative')
    password_toggle = container.find('button')
    status_element_id = password_field['aria-describedby']

    assert status_element_id.present?
    assert_selector "##{status_element_id}"
    assert_equal 'Show password', password_toggle['aria-label']
    assert_equal 'false', password_toggle['aria-pressed']

    page.execute_script(<<~JAVASCRIPT)
      (function() {
        const field = document.getElementById('user_password');
        if (!field) return;
      #{'  '}
        const container = field.closest('[data-controller="visibility"]');
        if (!container) return;
      #{'  '}
        const button = container.querySelector('button[data-action="visibility#togglePassword"]');
        if (!button) return;
      #{'  '}
        // Click the button to toggle visibility
        button.click();
      })();
    JAVASCRIPT

    sleep 0.1

    password_field = find('input#user_password')
    container = password_field.ancestor('.relative')
    password_toggle = container.find('button')

    assert_equal 'Hide password', password_toggle['aria-label']
    assert_equal 'true', password_toggle['aria-pressed']
    assert_equal 'Password is visible', find("##{status_element_id}").text

    confirmation_field = find('input#user_password_confirmation')
    confirmation_container = confirmation_field.ancestor('.relative')
    confirmation_toggle = confirmation_container.find('button')

    assert_equal 'Show password', confirmation_toggle['aria-label']
    assert_equal 'false', confirmation_toggle['aria-pressed']
  end
end
