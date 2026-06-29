# frozen_string_literal: true

require 'test_helper'

class PasswordsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    # Track performance for monitoring
    @start_time = Time.current

    # Create basic email templates needed for mailer functionality
    create_basic_email_templates

    @user = create(:constituent, password: 'password123', password_confirmation: 'password123')
    @original_password_digest = @user.password_digest

    # Standard sign-in for integration tests
    sign_in_for_integration_test(@user)
  end

  def teardown
    # Standard sign out for controller tests
    sign_out if respond_to?(:sign_out)

    # Log test execution time for performance monitoring
    @execution_time = Time.current - @start_time
    puts "PasswordsControllerTest #{name} took #{@execution_time.round(2)}s"
  end

  def test_should_get_edit
    get edit_password_path
    assert_response :success
    assert_select 'form[action=?]', password_path
    assert_select 'h2', text: 'Change Password'
    assert_select 'label', text: 'Current Password'
  end

  def test_should_redirect_unauthenticated_edit_without_token_to_account_access
    sign_out if respond_to?(:sign_out)

    get edit_password_path

    assert_redirected_to new_password_path
    assert_equal 'Use your account access link to reset your password.', flash[:alert]
  end

  def test_should_redirect_unauthenticated_update_without_token_to_account_access
    sign_out if respond_to?(:sign_out)

    patch password_path, params: {
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to new_password_path
    assert_equal 'Use your account access link to reset your password.', flash[:alert]
  end

  def test_should_send_account_access_email_for_existing_email
    assert_difference -> { Event.where(action: 'account_access_instructions_sent', user: @user).count }, 1 do
      assert_enqueued_emails 1 do
        post password_path, params: { contact: @user.email }
      end
    end

    assert_redirected_to sign_in_path
    assert_equal 'If the information you entered matches an account, we sent account access instructions to the contact information on record.',
                 flash[:notice]
  end

  def test_should_send_account_access_sms_for_existing_phone
    @user.update!(phone_type: 'text')

    SmsService.expects(:send_message)
              .with(@user.phone,
                    regexp_matches(%r{MAT account access link to set your password: https?://\S+ This link expires in 20 minutes\.}))
              .returns(true)

    assert_difference -> { Event.where(action: 'account_access_instructions_sent', user: @user).count }, 1 do
      assert_no_enqueued_emails do
        post password_path, params: { contact: @user.phone }
      end
    end

    assert_redirected_to sign_in_path
  end

  def test_should_return_generic_confirmation_when_sms_delivery_fails
    @user.update!(phone_type: 'text')

    SmsService.expects(:send_message).raises(StandardError, 'invalid number')

    assert_difference -> { Event.where(action: 'account_access_instructions_delivery_failed', user: @user).count }, 1 do
      post password_path, params: { contact: @user.phone }
    end

    assert_redirected_to sign_in_path
    assert_equal 'If the information you entered matches an account, we sent account access instructions to the contact information on record.',
                 flash[:notice]
  end

  def test_should_rate_limit_repeated_account_access_sms_requests
    @user.update!(phone_type: 'text')

    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    SmsService.expects(:send_message).times(PasswordsController::ACCOUNT_ACCESS_RATE_LIMIT).returns(true)

    (PasswordsController::ACCOUNT_ACCESS_RATE_LIMIT + 1).times do
      post password_path, params: { contact: @user.phone }
    end

    assert_equal 1, Event.where(action: 'account_access_instructions_rate_limited', user: @user).count
  ensure
    Rails.cache = old_cache
  end

  def test_should_return_generic_confirmation_for_unknown_contact
    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: 'unknown@example.com' }
    end

    assert_redirected_to sign_in_path
    assert_equal 'If the information you entered matches an account, we sent account access instructions to the contact information on record.',
                 flash[:notice]
  end

  def test_should_update_password_with_valid_token_without_current_password
    token = @user.generate_token_for(:password_reset)
    sign_out if respond_to?(:sign_out)

    get edit_password_path(token: token)
    assert_response :success
    assert_select 'h2', text: 'Reset Password'
    assert_select 'input[name=token][value=?]', token
    assert_select 'label', { text: 'Current Password', count: 0 }

    patch password_path, params: {
      token: token,
      password: 'TokenReset*Password123',
      password_confirmation: 'TokenReset*Password123'
    }

    assert_redirected_to sign_in_path
    assert_equal 'Password successfully updated.', flash[:notice]
    assert @user.reload.authenticate('TokenReset*Password123')
  end

  def test_should_update_password_with_valid_inputs
    patch password_path, params: {
      password_challenge: 'password123',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to constituent_portal_dashboard_path
    follow_redirect!
    assert_equal 'Password successfully updated.', flash[:notice]

    # Verify password was actually changed
    @user.reload
    assert_not_equal @original_password_digest, @user.password_digest
  end

  def test_should_redirect_turbo_stream_password_update_to_dashboard
    patch password_path,
          params: {
            password_challenge: 'password123',
            password: 'NewValid*Password123',
            password_confirmation: 'NewValid*Password123'
          },
          headers: { 'Accept' => 'text/vnd.turbo-stream.html' }

    assert_redirected_to constituent_portal_dashboard_path
    assert_response :see_other
  end

  def test_should_redirect_forced_password_change_without_mfa_to_welcome
    @user.update!(force_password_change: true)

    patch password_path, params: {
      password_challenge: 'password123',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to welcome_path
    assert_not @user.reload.force_password_change?
  end

  def test_should_redirect_required_role_without_mfa_to_setup_after_password_update
    sign_out
    admin = create(:admin, password: 'password123', password_confirmation: 'password123')
    sign_in_for_integration_test(admin)

    patch password_path, params: {
      password_challenge: 'password123',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to setup_two_factor_authentication_path
  end

  def test_should_not_update_password_with_wrong_current_password
    patch password_path, params: {
      password_challenge: 'wrongpassword',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_response :unprocessable_content
    assert_equal 'Current password is incorrect.', flash.now[:alert]

    # Verify password was not changed
    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end

  def test_should_not_update_password_with_mismatched_confirmation
    patch password_path, params: {
      password_challenge: 'password123', # Use the password set in setup
      password: 'NewValid*Password123',
      password_confirmation: 'DifferentPassword123'
    }

    assert_response :unprocessable_content
    assert_equal 'New password and confirmation do not match.', flash.now[:alert]

    # Verify password was not changed
    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end

  def test_should_not_update_password_with_invalid_new_password
    patch password_path, params: {
      password_challenge: 'password123', # Use the password set in setup
      password: 'short',
      password_confirmation: 'short'
    }

    assert_response :unprocessable_content
    # Check for model validation error message in the flash
    assert_equal 'Unable to update password. Please check requirements., Password is too short (minimum is 8 characters)', flash.now[:alert]

    # Verify password was not changed
    @user.reload
    assert_equal @original_password_digest, @user.password_digest
  end


  def test_system_email_does_not_fall_through_to_phone_for_account_access
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  email: "dep.#{SecureRandom.hex(3)}@system.matvulcan.local",
                  phone: '410-555-0166',
                  password: 'password123',
                  password_confirmation: 'password123')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: user.email }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_placeholder_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  phone: '000-000-4321',
                  email: "real.#{SecureRandom.hex(3)}@example.com",
                  password: 'password123',
                  password_confirmation: 'password123')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: user.phone }
    end

    assert_redirected_to sign_in_path
  end

  def test_guardian_generated_synthetic_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  phone: '000-345-6789',
                  email: "real.#{SecureRandom.hex(3)}@example.com",
                  password: 'password123',
                  password_confirmation: 'password123')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '0003456789' }
    end

    assert_redirected_to sign_in_path
  end

  def test_account_access_accepts_email_with_surrounding_whitespace
    sign_out if respond_to?(:sign_out)

    assert_enqueued_emails 1 do
      post password_path, params: { contact: "  #{@user.email}  " }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_voice_phone_does_not_receive_account_access_sms
    sign_out if respond_to?(:sign_out)

    user = create(:constituent,
                  phone: '410-555-0144',
                  phone_type: 'voice',
                  email: "voice.#{SecureRandom.hex(3)}@example.com",
                  password: 'password123',
                  password_confirmation: 'password123')

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: user.phone }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
  end

  def test_malformed_email_shaped_account_access_does_not_fall_through_to_phone
    sign_out if respond_to?(:sign_out)

    phone = '410-555-0164'
    Current.paper_context = true
    user = nil
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyMalformedAccess',
        phone: phone,
        phone_type: 'text',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '4105550164@' }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_equal user, User.find_by_phone(phone)
  end

  def test_email_shaped_account_access_does_not_fall_through_to_phone
    sign_out if respond_to?(:sign_out)

    phone = '410-555-0165'
    Current.paper_context = true
    user = nil
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyAccess',
        phone: phone,
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    SmsService.expects(:send_message).never

    assert_no_enqueued_emails do
      post password_path, params: { contact: '4105550165@example.com' }
    end

    assert_redirected_to sign_in_path
    assert_equal account_access_confirmation_message, flash[:notice]
    assert_equal user, User.find_by_phone(phone)
  end

  def account_access_confirmation_message
    'If the information you entered matches an account, we sent account access instructions to the contact information on record.'
  end

  private

  def create_basic_email_templates
    # Create header and footer templates if they don't exist
    unless EmailTemplate.exists?(name: 'email_header_text', format: :text)
      EmailTemplate.create!(
        name: 'email_header_text',
        format: :text,
        subject: 'Header Template',
        description: 'Email header template for testing',
        body: 'Maryland Accessible Telecommunications Program'
      )
    end

    return if EmailTemplate.exists?(name: 'email_footer_text', format: :text)

    EmailTemplate.create!(
      name: 'email_footer_text',
      format: :text,
      subject: 'Footer Template',
      description: 'Email footer template for testing',
      body: 'Contact us at support@mat.maryland.gov'
    )
  end
end
