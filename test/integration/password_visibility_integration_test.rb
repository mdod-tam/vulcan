# frozen_string_literal: true

require 'test_helper'

class PasswordVisibilityIntegrationTest < ActionDispatch::IntegrationTest
  test 'password visibility toggle works on sign in page' do
    get sign_in_path
    assert_response :success

    # Check that the toggle button exists with correct attributes
    assert_select "button[aria-label='Show password']"
    assert_select "button[aria-pressed='false']"
    # Check for the SVG icon within the button, assuming the controller adds/removes classes there
    assert_select "button[aria-label='Show password'] svg"
  end

  test 'password visibility toggle works on registration page' do
    get sign_up_path
    assert_response :success

    # Check that both password fields have toggle buttons
    assert_select "input#user_password + button[aria-label='Show password']"
    assert_select "input#user_password_confirmation + button[aria-label='Show password']"
  end

  test 'password visibility toggle works on password reset page' do
    # Create a real user and generate a valid reset token
    user = create(:user)

    # Generate a valid password reset token using Rails' token system
    token = user.generate_token_for(:password_reset)

    # Visit the edit path with the valid token
    get edit_password_path(token: token)
    assert_response :success

    # Check that password fields exist within the visibility controller div
    # We test button existence/attributes in other tests
    assert_select "div[data-controller='visibility'] input[type='password']", count: 2 # password, confirmation
  end

  test 'password visibility toggle has correct accessibility attributes' do
    get sign_up_path
    assert_response :success

    # Check that the toggle button has the correct accessibility attributes
    assert_select "button[aria-label='Show password']" do |elements|
      elements.each do |element|
        assert_equal 'false', element['aria-pressed']
        # Check the class on the SVG icon inside the button
        assert element.css('svg').first['class'].present?, 'SVG icon should have classes'
        # NOTE: We might need a more specific class check depending on the controller's implementation
        # For now, just checking for presence of any class on the SVG.
      end
    end
  end

  test 'password visibility toggle has data-controller attribute' do
    get sign_up_path
    assert_response :success

    # Check that the toggle button has the correct data-controller attribute
    assert_select "div[data-controller='visibility']"
    assert_select "button[data-action*='visibility#toggle']"
  end

  test 'password visibility toggle has timeout value' do
    get sign_up_path
    assert_response :success

    # Check that the toggle button has the correct data-visibility-timeout-value attribute
    assert_select 'div[data-visibility-timeout-value]'
  end
end
