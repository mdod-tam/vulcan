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

    assert toggle_password_visibility('user_password')

    assert_selector "input#user_password[type='text']"
    password_field = find('input#user_password')
    container = password_field.ancestor('[data-controller="visibility"]')
    password_toggle = container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'true', password_toggle['aria-pressed']

    assert_equal '5000', container['data-visibility-timeout-value']

    assert_selector "input#user_password[type='password']", wait: 6
    password_toggle = container.find('button[data-action="visibility#togglePassword"]')
    assert_equal 'false', password_toggle['aria-pressed']
    assert_equal 'Show password', password_toggle['aria-label']
    assert_equal 'Password is hidden', container.find('[data-visibility-target="status"]', visible: :all).text(:all)
    take_screenshot('password-visibility-hidden-after-timeout')
  end

  test 'password fields have correct accessibility attributes' do
    visit sign_up_path
    ensure_stimulus_loaded

    %w[user_password user_password_confirmation].each do |field_id|
      password_field = find("input##{field_id}")
      container = password_field.ancestor('[data-controller="visibility"]')
      password_toggle = container.find('button[data-action="visibility#togglePassword"]')
      status_element = container.find('[data-visibility-target="status"]', visible: :all)

      assert_includes password_field['aria-describedby'].split, status_element['id']
      assert_equal 'polite', status_element['aria-live']
      assert_equal 'Show password', password_toggle['aria-label']
      assert_equal 'false', password_toggle['aria-pressed']
      assert_equal 'Password is hidden', status_element.text(:all)
      assert_equal 'true', container.find('svg')['aria-hidden']

      password_toggle.click

      assert_selector "input##{field_id}[type='text']"
      assert_equal 'Hide password', password_toggle['aria-label']
      assert_equal 'true', password_toggle['aria-pressed']
      assert_equal 'Password is visible', status_element.text(:all)

      password_toggle.click

      assert_selector "input##{field_id}[type='password']"
      assert_equal 'Show password', password_toggle['aria-label']
      assert_equal 'false', password_toggle['aria-pressed']
      assert_equal 'Password is hidden', status_element.text(:all)
    end
    take_screenshot('password-visibility-accessibility')
  end
end
