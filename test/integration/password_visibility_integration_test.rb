# frozen_string_literal: true

require 'test_helper'

class PasswordVisibilityIntegrationTest < ActionDispatch::IntegrationTest
  test 'password visibility toggle works on sign in page' do
    get sign_in_path
    assert_response :success

    assert_select "button[aria-label='Show password']"
    assert_select "button[aria-pressed='false']"
    assert_select "button[aria-label='Show password'] svg"
  end

  test 'password visibility toggle works on registration page' do
    get sign_up_path
    assert_response :success

    assert_select "input#user_password + button[aria-label='Show password']"
    assert_select "input#user_password_confirmation + button[aria-label='Show password']"
  end

  test 'password visibility toggle works on password reset page' do
    user = create(:user)

    token = user.generate_token_for(:password_reset)

    get edit_password_path(token: token)
    assert_response :success

    assert_select "div[data-controller='visibility'] input[type='password']", count: 2 # password, confirmation
  end

  test 'password visibility toggle has correct accessibility attributes' do
    get sign_up_path
    assert_response :success

    assert_select "button[aria-label='Show password']" do |elements|
      elements.each do |element|
        assert_equal 'false', element['aria-pressed']
        assert element.css('svg').first['class'].present?, 'SVG icon should have classes'
      end
    end
  end

  test 'password visibility toggle has data-controller attribute' do
    get sign_up_path
    assert_response :success

    assert_select "div[data-controller='visibility']"
    assert_select "button[data-action*='visibility#toggle']"
  end

  test 'password visibility toggle has timeout value' do
    get sign_up_path
    assert_response :success

    assert_select 'div[data-visibility-timeout-value]'
  end
end
