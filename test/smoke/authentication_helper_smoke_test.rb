# frozen_string_literal: true

require 'test_helper'

# CI smoke coverage for persisted-session helpers and browser isolation.
if ENV['CI']
  class AuthenticationHelperSmokeTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    include AuthenticationCore

    setup do
      Current.user = nil if defined?(Current)
    end

    teardown do
      Current.user = nil if defined?(Current)
    end

    test 'can create a valid session record' do
      user = create(:user, password: 'password1234', verified: true)

      session = create_test_session(user)

      assert_not_nil session
      assert_not_nil session.session_token
      assert_equal user.id, session.user_id
      assert_equal 'Test Browser', session.user_agent
      assert_equal '127.0.0.1', session.ip_address
    end

    test 'Current.user can be set and cleared' do
      user = create(:user, password: 'password1234', verified: true)

      Current.user = user if defined?(Current)

      assert_equal user, Current.user if defined?(Current)

      Current.user = nil if defined?(Current)

      assert_nil Current.user if defined?(Current)
    end

    test 'integration helper permits profile access and sign_out sends root to sign-in' do
      user = create(:user, password: 'password1234', verified: true)

      sign_in_for_integration_test(user)

      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'section[aria-labelledby="contact-heading"]', text: /#{Regexp.escape(user.email)}/

      sign_out

      get root_path
      assert_redirected_to sign_in_path
    end

    test 'sign_out sends root to sign-in before a second user signs in' do
      user1 = create(:user, password: 'password1234', verified: true)
      user2 = create(:user, password: 'password1234', verified: true)

      sign_in_for_integration_test(user1)

      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'section[aria-labelledby="contact-heading"]', text: /#{Regexp.escape(user1.email)}/
      assert_select 'section[aria-labelledby="contact-heading"]', text: /#{Regexp.escape(user2.email)}/, count: 0

      sign_out

      get root_path
      assert_redirected_to sign_in_path

      sign_in_for_integration_test(user2)

      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'section[aria-labelledby="contact-heading"]', text: /#{Regexp.escape(user2.email)}/
      assert_select 'section[aria-labelledby="contact-heading"]', text: /#{Regexp.escape(user1.email)}/, count: 0

      sign_out
    end
  end
end
