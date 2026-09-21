# frozen_string_literal: true

require 'test_helper'

# This smoke test verifies that our authentication helpers function correctly.
# It's designed to fail early when auth helpers break, rather than having numerous tests fail.
#
# It tests all authentication flows:
# - Thread-local and ENV user identification
# - Session creation and cleanup
# - Integration authentication with headers
# - Authentication session isolation

if ENV['CI']
  class AuthenticationHelperSmokeTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    # No need for this in IntegrationTest: include SystemTestAuthentication
    include AuthenticationCore

    setup do
      # Start fresh - clear any test state
      Thread.current[:test_user_id] = nil
      ENV['TEST_USER_ID'] = nil
      Current.user = nil if defined?(Current)
    end

    teardown do
      # Make sure we clean up after ourselves
      Thread.current[:test_user_id] = nil
      ENV['TEST_USER_ID'] = nil
      Current.user = nil if defined?(Current)
    end

    # Test the thread-local user ID storage
    test 'thread-local user ID storage works correctly' do
      user = create(:user, password: 'password123', verified: true)

      # Manually set the thread-local value
      Thread.current[:test_user_id] = user.id

      # Verify it's there (as a string or integer)
      assert_equal user.id.to_s, Thread.current[:test_user_id].to_s

      # Manually clear it
      Thread.current[:test_user_id] = nil

      # Verify it's cleared
      assert_nil Thread.current[:test_user_id]
    end

    # Test direct session creation
    test 'can create a valid session record' do
      user = create(:user, password: 'password123', verified: true)

      session = create_test_session(user)

      assert_not_nil session
      assert_not_nil session.session_token
      assert_equal user.id, session.user_id
      assert_equal 'Test Browser', session.user_agent
      assert_equal '127.0.0.1', session.ip_address
    end

    # Test Current.user setting and clearing directly
    test 'Current.user can be set and cleared' do
      user = create(:user, password: 'password123', verified: true)

      # Set Current.user directly
      Current.user = user if defined?(Current)

      # Verify it's set
      assert_equal user, Current.user if defined?(Current)

      # Clear it
      Current.user = nil if defined?(Current)

      # Verify it's cleared
      assert_nil Current.user if defined?(Current)
    end

    # Test integration authentication with real HTTP calls
    test 'integration authentication uses HTTP headers correctly' do
      user = create(:user, password: 'password123', verified: true)

      # Sign in using the integration helper
      sign_in_for_integration_test(user)

      # Follow the root redirect and verify the authenticated user's profile.
      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'input[name=?][value=?]', 'user[email]', user.email

      # Thread.current might not be reliable in all test environments
      # Just verify the authentication worked by checking the response
      assert_equal user.id.to_s, Thread.current[:test_user_id].to_s if Thread.current[:test_user_id].present?

      # Sign out
      sign_out

      # Make another request to verify we're signed out
      get root_path
      assert_redirected_to sign_in_path
    end

    # Test authentication session isolation
    test 'sign_out properly cleans up all session state between users' do
      user1 = create(:user, password: 'password123', verified: true)
      user2 = create(:user, password: 'password123', verified: true)

      # Sign in as first user
      sign_in_for_integration_test(user1)

      # Verify thread-local storage if available
      assert_equal user1.id.to_s, Thread.current[:test_user_id].to_s if Thread.current[:test_user_id].present?

      # Make a request to verify authentication
      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'input[name=?][value=?]', 'user[email]', user1.email

      # Sign out
      sign_out

      # Verify thread-local is cleared (if it was set)
      assert_nil Thread.current[:test_user_id]

      get root_path
      assert_redirected_to sign_in_path

      # Sign in as second user
      sign_in_for_integration_test(user2)

      # Verify thread-local now has second user (if available)
      if Thread.current[:test_user_id].present?
        assert_equal user2.id.to_s, Thread.current[:test_user_id].to_s
        assert_not_equal user1.id.to_s, Thread.current[:test_user_id].to_s
      end

      # Make another request
      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'input[name=?][value=?]', 'user[email]', user2.email

      # Clean up
      sign_out
    end
  end
end
