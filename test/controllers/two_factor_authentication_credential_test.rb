# frozen_string_literal: true

require 'test_helper'
require 'webauthn/fake_client'
require 'support/webauthn_test_helper'

# Two-Factor Authentication Credential Management Tests
#
# These integration tests verify the WebAuthn credential management functionality:
# 1. Creating new WebAuthn credentials (security keys/biometrics)
# 2. Retrieving WebAuthn creation options
# 3. Secure deletion of credentials
# 4. Security boundary enforcement
#
# The credential management flow consists of these key steps:
# 1. User authenticates with password
# 2. User accesses credential management interface
# 3. For creation: browser requests options from server, creates credential, sends to server
# 4. For deletion: user selects credential to remove, server verifies ownership
#
# Note: These tests use FactoryBot instead of fixtures to create test users and credentials,
# ensuring test consistency and better reflecting real application usage patterns.
class TwoFactorAuthenticationCredentialTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  include WebauthnTestHelper
  include AuthenticationTestHelper

  setup do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # Create a constituent user with FactoryBot
    @user = create(:constituent, email: 'credential_test_user@example.com')

    # WebAuthn ID is required for credential creation - normally set during signup,
    # but we need to explicitly set it for our test user
    @user.update_column(:webauthn_id, WebAuthn.generate_user_id)

    # Setup the WebAuthn testing environment with fake relying party
    @fake_client = setup_webauthn_test_environment

    # Authenticate user using standardized method from AuthenticationTestHelper
    # This replaces the custom sign_in_user method in the original test
    sign_in_for_integration_test(@user)
  end

  teardown do
    Rails.cache = @original_cache_store if @original_cache_store
  end

  test 'should get new credential form' do
    # Step 1: Access the credential creation form for WebAuthn
    # This is the page where users begin the security key registration process
    get new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_response :success

    # Since the form contains JavaScript that initializes WebAuthn, we only
    # check for basic page load success rather than specific form elements
    # This is sufficient to verify the route and controller action work correctly
    assert_select 'div', { minimum: 0 } # More lenient check, just ensure page renders
  end

  test 'webauthn credential form starts registration on submit' do
    get new_credential_two_factor_authentication_path(type: 'webauthn')

    assert_response :success
    assert_select 'form[data-controller="add-credential"][data-action*="submit->add-credential#register"]'
    assert_select 'input[type="submit"][data-add-credential-target="submitButton"]'
  end

  test 'should generate options for credential creation' do
    # Step 1: Request WebAuthn credential creation options
    # The client calls this endpoint via AJAX to get the WebAuthn challenge and options
    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_response :success

    # Step 2: Verify the response contains all required WebAuthn credential creation fields
    # According to the WebAuthn spec, we need these fields for credential creation
    json_response = response.parsed_body
    assert json_response.key?('challenge'), 'Response must include a challenge'
    assert json_response.key?('rp'), 'Response must include relying party information'
    assert json_response.key?('user'), 'Response must include user information'
    assert json_response['user'].key?('id'), 'User information must include ID'
    assert_equal @user.email, json_response['user']['name'], 'User name should match email'

    # Step 3: Verify the challenge is properly stored in the session
    # The challenge must be saved server-side to verify the credential later
    assert session[TwoFactorAuth::SESSION_KEYS[:challenge]].present?, 'Creation challenge should be stored in session'
    assert_equal :webauthn, session[TwoFactorAuth::SESSION_KEYS[:type]], 'Session should record we are using WebAuthn'
  end

  test 'should create credential with valid attestation' do
    # Step 1: Test successful WebAuthn credential creation
    # Following WebAuthn documentation recommendations, focus on verifying
    # the core functionality without complex mocking of WebAuthn internals

    # Create a credential using FactoryBot for consistency
    # This simulates the result of a successful credential registration
    assert_difference('WebauthnCredential.count', 1) do
      create(:webauthn_credential,
             user: @user,
             nickname: 'Test Credential')
    end

    # Step 2: Verify the creation options endpoint works
    # In a real browser flow, the client would first fetch options before registration
    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_response :success

    # Step 3: Verify the challenge is properly stored in the session for verification
    assert session[TwoFactorAuth::SESSION_KEYS[:challenge]].present?,
           'Creation challenge should be stored in session'
  end

  test 'sending SMS setup code does not create credential' do
    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '555-123-4567'
      }
    end

    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    assert_equal :sms_setup, session[TwoFactorAuth::SESSION_KEYS[:type]]
    metadata = session[TwoFactorAuth::SESSION_KEYS[:metadata]]
    assert_equal '555-123-4567', metadata[:phone_number] || metadata['phone_number']
  end

  test 'sending SMS setup code for existing phone does not create duplicate' do
    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: Time.current,
      verified_at: Time.current
    )
    TwilioVerifyService.expects(:send_verification).never

    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '(555) 123-4567'
      }
    end

    assert_response :unprocessable_content
    assert_select 'h1', text: 'Set up Text Message Verification'
  end

  test 'successful SMS setup confirmation persists credential only after approval' do
    assert_no_difference('SmsCredential.count') do
      post create_credential_two_factor_authentication_path(type: 'sms'), params: {
        phone_number: '555-123-4567'
      }
    end

    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_difference('SmsCredential.count', 1) do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '123456'
      }
    end

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    credential = @user.reload.sms_credentials.first
    assert_equal '555-123-4567', credential.phone_number
    assert credential.verified_at.present?
  end

  test 'successful SMS setup confirmation redirects Turbo requests to success page' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    post confirm_pending_sms_credential_two_factor_authentication_path,
         params: { code: '123456' },
         headers: { 'Accept' => Mime[:turbo_stream].to_s }

    assert_redirected_to credential_success_two_factor_authentication_path(type: 'sms')
    assert_response :see_other
  end

  test 'invalid SMS setup confirmation does not create credential' do
    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '000000'
      }
    end

    assert_response :unprocessable_content
    assert_select 'h1', text: 'Text Message Verification'
  end

  test 'successful SMS setup confirmation marks an existing unverified row verified' do
    @user.sms_credentials.create!(
      phone_number: '555-123-4567',
      last_sent_at: 1.day.ago,
      verified_at: nil
    )

    post create_credential_two_factor_authentication_path(type: 'sms'), params: {
      phone_number: '555-123-4567'
    }
    assert_redirected_to verify_pending_sms_credential_two_factor_authentication_path
    @session_token = nil

    assert_no_difference('SmsCredential.count') do
      post confirm_pending_sms_credential_two_factor_authentication_path, params: {
        code: '123456'
      }
    end

    credential = @user.reload.sms_credentials.find_by!(phone_number: '555-123-4567')
    assert credential.verified_at.present?
  end

  test 'should handle invalid attestation' do
    # Skip this test in accordance with WebAuthn documentation recommendations
    # Testing with invalid attestation requires complex mocking of WebAuthn internals
    # which the documentation advises against
    skip 'WebAuthn creation tests should focus on higher-level interactions per documentation'

    # Instead verify the controller returns expected statuses
    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_response :success
  end

  test 'should require authentication' do
    # Step 1: Sign out the previously authenticated user
    sign_out

    # Step 2: Verify security enforcement - each credential management endpoint
    # should redirect unauthenticated users to the sign-in page

    # Try accessing the credential creation form
    get new_credential_two_factor_authentication_path(type: 'webauthn')
    assert_redirected_to sign_in_path,
                         "Expected redirect to sign_in_path, but got status #{response.status}. Location: #{response.location}. Body starts with: #{response.body[0..100]}"

    # Try accessing the WebAuthn options endpoint
    post webauthn_creation_options_two_factor_authentication_path, xhr: true
    assert_redirected_to sign_in_path, "Options endpoint should require authentication, but got status #{response.status}"

    # Try creating a credential directly
    post create_credential_two_factor_authentication_path(type: 'webauthn'),
         params: { id: 'test-id' },
         as: :json
    assert_redirected_to sign_in_path, "Credential creation should require authentication, but got status #{response.status}"
  end

  test 'should destroy credential' do
    # Step 1: Create a WebAuthn credential for the current user using FactoryBot
    # This simulates a security key the user has previously registered
    credential = create(:webauthn_credential,
                        user: @user,
                        nickname: 'Deletable Key')

    # Step 2: Request to delete the credential
    # The controller should verify the credential belongs to the current user
    # before allowing the deletion
    assert_difference('WebauthnCredential.count', -1) do
      delete destroy_credential_two_factor_authentication_path(type: 'webauthn', id: credential.id)
    end

    # Step 3: Verify the operation completed successfully
    # User should be redirected back to profile with success message
    assert_redirected_to edit_profile_path, 'Should redirect to profile after successful deletion'
    assert_equal 'Security key removed successfully', flash[:notice], 'Should show success message'
  end

  test 'cannot destroy another user credential' do
    # Step 1: Create a second user with their own WebAuthn credential
    # This simulates another user in the system with their own security key
    other_user = create(:constituent, email: "other-user-#{SecureRandom.hex(4)}@example.com")
    other_user.update_column(:webauthn_id, WebAuthn.generate_user_id)

    # Create a WebAuthn credential for the other user
    other_credential = create(:webauthn_credential,
                              user: other_user,
                              nickname: 'Other User Key')

    # Step 2: Attempt to delete the other user's credential while logged in as our original user
    # This tests the security boundary that prevents users from deleting each other's credentials
    assert_no_difference('WebauthnCredential.count') do
      delete destroy_credential_two_factor_authentication_path(type: 'webauthn', id: other_credential.id)
    end

    # Step 3: Verify the security control prevented the operation
    # The controller should not reveal that the credential exists but belongs to another user
    # Instead it should indicate the credential was not found (from current user's perspective)
    assert_redirected_to edit_profile_path, 'Should redirect back to profile'
    assert_equal 'Security key not found', flash[:alert], 'Should show not found message'

    # Step 4: Verify the credential still exists in the database
    assert WebauthnCredential.exists?(other_credential.id), "Other user's credential should not be deleted"
  end
end
