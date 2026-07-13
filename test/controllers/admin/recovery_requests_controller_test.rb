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

    test 'does not approve or remove credentials when approval notification cannot be created' do
      NotificationService.expects(:create_and_deliver!).returns(nil)

      assert_no_difference -> { WebauthnCredential.where(user_id: @user.id).count } do
        assert_no_difference -> { Event.where(action: 'security_key_recovery_approved').count } do
          post approve_admin_recovery_request_path(@recovery_request)
        end
      end

      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_match(/notification could not be created or queued/i, flash[:alert])

      @recovery_request.reload
      assert_equal 'pending', @recovery_request.status
      assert_nil @recovery_request.resolved_at
      assert_nil @recovery_request.resolved_by_id
      assert @user.webauthn_credentials.exists?
    end

    test 'does not approve or remove credentials when approval notification delivery errors synchronously' do
      failed_notification = Notification.create!(
        recipient: @user,
        actor: @admin,
        action: 'security_key_recovery_approved',
        notifiable: @recovery_request,
        delivery_status: 'error'
      )
      NotificationService.expects(:create_and_deliver!).returns(failed_notification)

      assert_no_difference -> { WebauthnCredential.where(user_id: @user.id).count } do
        post approve_admin_recovery_request_path(@recovery_request)
      end

      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_equal 'pending', @recovery_request.reload.status
      assert @user.webauthn_credentials.exists?
    end

    test 'cannot replay approval on already resolved recovery request' do
      @recovery_request.update!(
        status: 'approved',
        resolved_at: Time.current,
        resolved_by_id: @admin.id
      )
      setup_webauthn_credential(@user)

      assert_no_difference '@user.webauthn_credentials.count' do
        post approve_admin_recovery_request_path(@recovery_request)
      end

      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_match(/already been resolved/i, flash[:alert])

      @recovery_request.reload
      assert_equal 'approved', @recovery_request.status
      assert_equal @admin.id, @recovery_request.resolved_by_id
      assert @user.webauthn_credentials.exists?
    end

    test 'does not approve recovery for a retired user' do
      canonical = create(:constituent)
      @user.update_columns(
        status: User.statuses[:inactive], merged_into_user_id: canonical.id,
        merged_at: Time.current, email: nil, phone: nil
      )

      assert_no_difference '@user.webauthn_credentials.count' do
        post approve_admin_recovery_request_path(@recovery_request)
      end

      assert_redirected_to admin_recovery_request_path(@recovery_request)
      assert_match(/no longer active/i, flash[:alert])
      assert_equal 'pending', @recovery_request.reload.status
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
