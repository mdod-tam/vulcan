# frozen_string_literal: true

require 'test_helper'
require 'webauthn/fake_client'

module Admin
  class RecoveryRequestsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      # Create admin and user with unique emails
      @admin = FactoryBot.create(:admin, email: "admin-recovery-#{SecureRandom.hex(4)}@example.com")
      @user = FactoryBot.create(:user, email: "user-recovery-#{SecureRandom.hex(4)}@example.com")

      # Ensure user has WebAuthn credentials
      setup_webauthn_credential(@user)

      # Create a recovery request
      @recovery_request = FactoryBot.create(:recovery_request, user: @user)

      # Sign in as admin
      sign_in_for_integration_test(@admin)
    end

    test 'should get index' do
      get admin_recovery_requests_path
      assert_response :success
      assert_select 'h1', 'Security Key Recovery Requests'
    end

    test 'should get show' do
      get admin_recovery_request_path(@recovery_request)
      assert_response :success
      assert_select 'h1', 'Security Key Recovery Request'
    end

    test 'should approve recovery request' do
      assert_difference '@user.webauthn_credentials.count', -@user.webauthn_credentials.count do
        post approve_admin_recovery_request_path(@recovery_request)
      end

      assert_redirected_to admin_recovery_requests_path

      # Check that request is updated
      @recovery_request.reload
      assert_equal 'approved', @recovery_request.status
      assert_not_nil @recovery_request.resolved_at
      assert_equal @admin.id, @recovery_request.resolved_by_id

      # Check that user's credentials were deleted
      assert_equal 0, @user.reload.webauthn_credentials.count
    end

    test 'should not allow non-admins to access requests' do
      # Sign out admin
      delete sign_out_path

      # Sign in as regular user
      @regular_user = FactoryBot.create(:user, email: "regular-#{SecureRandom.hex(4)}@example.com")
      sign_in_for_integration_test(@regular_user)

      get admin_recovery_requests_path
      assert_redirected_to root_path

      get admin_recovery_request_path(@recovery_request)
      assert_redirected_to root_path

      post approve_admin_recovery_request_path(@recovery_request)
      assert_redirected_to root_path

      # Request should remain unchanged
      @recovery_request.reload
      assert_equal 'pending', @recovery_request.status
    end

    private

    def setup_webauthn_credential(user)
      WebAuthn.configure do |config|
        config.allowed_origins = ['https://example.com']
      end
      fake_client = WebAuthn::FakeClient.new('https://example.com')

      credential_options = WebAuthn::Credential.options_for_create(user: { id: user.id, name: user.email })
      credential_hash = fake_client.create(challenge: credential_options.challenge)

      user.webauthn_credentials.create!(
        external_id: credential_hash['id'],
        public_key: 'dummy_public_key_for_testing',
        nickname: 'Test Key',
        sign_count: 0
      )
    end
  end
end
