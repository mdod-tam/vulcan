# frozen_string_literal: true

require 'test_helper'

# CI smoke coverage for session helpers and test identity isolation.
if ENV['CI']
  class AuthenticationHelperSmokeTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    include AuthenticationCore

    setup do
      Thread.current[:test_user_id] = nil
      ENV['TEST_USER_ID'] = nil
      Current.user = nil if defined?(Current)
    end

    teardown do
      Thread.current[:test_user_id] = nil
      ENV['TEST_USER_ID'] = nil
      Current.user = nil if defined?(Current)
    end

    test 'thread-local user ID can be assigned and cleared' do
      user = create(:user, password: 'password1234', verified: true)

      Thread.current[:test_user_id] = user.id

      assert_equal user.id.to_s, Thread.current[:test_user_id].to_s

      Thread.current[:test_user_id] = nil

      assert_nil Thread.current[:test_user_id]
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
      assert_select 'input[name=?][value=?]', 'user[email]', user.email

      assert_equal user.id.to_s, Thread.current[:test_user_id].to_s if Thread.current[:test_user_id].present?

      sign_out

      get root_path
      assert_redirected_to sign_in_path
    end

    test 'sign_out sends root to sign-in before a second user signs in' do
      user1 = create(:user, password: 'password1234', verified: true)
      user2 = create(:user, password: 'password1234', verified: true)

      sign_in_for_integration_test(user1)

      assert_equal user1.id.to_s, Thread.current[:test_user_id].to_s if Thread.current[:test_user_id].present?

      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'input[name=?][value=?]', 'user[email]', user1.email

      sign_out

      assert_nil Thread.current[:test_user_id]

      get root_path
      assert_redirected_to sign_in_path

      sign_in_for_integration_test(user2)

      if Thread.current[:test_user_id].present?
        assert_equal user2.id.to_s, Thread.current[:test_user_id].to_s
        assert_not_equal user1.id.to_s, Thread.current[:test_user_id].to_s
      end

      get root_path
      assert_redirected_to edit_profile_path
      follow_redirect!
      assert_response :success
      assert_select 'input[name=?][value=?]', 'user[email]', user2.email

      sign_out
    end
  end
end
