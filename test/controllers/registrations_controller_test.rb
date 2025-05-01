# frozen_string_literal: true

require 'test_helper'

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup do
    # Clear emails before each test
    ActionMailer::Base.deliveries.clear

    # Ensure the required email template exists for tests, creating it only if necessary.
    # Using find_or_create_by! ensures idempotency across test runs.
    EmailTemplate.find_or_create_by!(name: 'application_notifications_registration_confirmation') do |template|
      admin = User.find_by(email: 'david.bahar@maryland.gov') || create(:admin, email: 'david.bahar@maryland.gov') # Ensure admin exists

      template.assign_attributes(
        format: :text,
        subject: 'Welcome to the Maryland Accessible Telecommunications Program',
        body: 'This is a test text body for registration confirmation. %<user_first_name>s, %<user_full_name>s, %<dashboard_url>s, %<new_application_url>s, %<header_text>s, %<footer_text>s, %<active_vendors_text_list>s',
        description: 'Sent to a user upon successful account registration confirmation.',
        updated_by: admin
        # NOTE: `create!` behavior is implicit within find_or_create_by! block assignment + save
      )
      # No need to explicitly call save!, find_or_create_by! handles it.
    end
  end

  teardown do
    # Clear emails after each test
    # Clean up after tests
    ActionMailer::Base.deliveries.clear
  end
  def test_should_get_new
    get sign_up_path
    assert_response :success
  end

  def test_should_create_constituent_with_required_fields
    assert_difference('User.count') do
      post sign_up_path, params: { user: {
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: '555-555-5555',
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        # Disabilities are required for constituents
        hearing_disability: true,
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false
      } }
    end

    assert_redirected_to welcome_path
    assert_equal 'Account created successfully. Welcome!', flash[:notice]

    # Verify user was created correctly
    user = User.last
    assert_equal 'Users::Constituent', user.type # Correct STI class name
    assert user.hearing_disability
    assert_not user.vision_disability
    assert_equal 'newuser@example.com', user.email
  end

  # Renamed test to reflect correct behavior: disability is NOT required at registration
  def test_should_create_constituent_without_disabilities
    # User should be created successfully even without disability flags
    assert_difference('User.count', 1) do
      post sign_up_path, params: { user: {
        email: 'nodisability@example.com', # Use a unique email for this test
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: '555-555-5555',
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: false, # No disability selected
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false
      } }
    end

    # Should succeed and redirect
    assert_redirected_to welcome_path
    assert_equal 'Account created successfully. Welcome!', flash[:notice]

    # Verify user was created correctly without disability flags set
    user = User.find_by(email: 'nodisability@example.com')
    assert_not_nil user
    assert_not user.disability_selected?, 'User should not have any disability flags set at registration'
  end

  def test_should_not_create_user_with_invalid_phone
    assert_no_difference('User.count') do
      post sign_up_path, params: { user: {
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: 'invalid-phone', # Invalid format
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: true
      } }
    end

    assert_response :unprocessable_entity
    # Check errors directly on the instance variable assigned by the controller
    assert_includes assigns(:user).errors[:phone], 'must be a valid 10-digit US phone number'
  end

  def test_should_not_create_user_with_existing_email
    # Use FactoryBot to create an existing user
    existing_user = create(:constituent)

    assert_no_difference('User.count') do
      post sign_up_path, params: { user: {
        email: existing_user.email, # Already exists
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: '555-555-5555',
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: true
      } }
    end

    assert_response :unprocessable_entity
    # Check errors directly on the instance variable assigned by the controller
    assert_includes assigns(:user).errors[:email], 'has already been taken'
  end

  def test_should_not_create_user_with_existing_phone
    # Use FactoryBot to create an existing user with a specific phone
    create(:constituent, phone: '555-999-8888')

    assert_no_difference('User.count') do
      post sign_up_path, params: { user: {
        email: 'anothernew@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: '555-999-8888', # Already exists
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: true
      } }
    end

    assert_response :unprocessable_entity
    # Check errors directly on the instance variable assigned by the controller
    assert_includes assigns(:user).errors[:phone], 'has already been taken'
  end

  def test_should_create_user_but_flag_for_review_on_name_dob_match
    # Create an existing user with specific details
    create(:constituent, first_name: 'Duplicate', last_name: 'User', date_of_birth: '1985-05-15')

    # Attempt to create a new user with the same name and DOB, but different email/phone
    assert_difference('User.count', 1) do
      post sign_up_path, params: { user: {
        email: 'duplicate_name_dob@example.com', # Unique email
        password: 'password123',
        password_confirmation: 'password123',
        first_name: 'Duplicate', # Same first name (case difference handled by controller)
        last_name: 'USER',       # Same last name (case difference handled by controller)
        date_of_birth: '1985-05-15', # Same DOB
        phone: '555-123-4567', # Unique phone
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: true
      } }
    end

    # Should still redirect successfully
    assert_redirected_to welcome_path
    assert_equal 'Account created successfully. Welcome!', flash[:notice]

    # Verify the new user was created AND flagged
    new_user = User.find_by(email: 'duplicate_name_dob@example.com')
    assert_not_nil new_user, 'New user should have been created despite name/DOB match'
    assert new_user.needs_duplicate_review, 'User should be flagged for duplicate review'
  end

  def test_should_not_create_user_with_mismatched_passwords
    assert_no_difference('User.count') do
      post sign_up_path, params: { user: {
        email: 'newuser@example.com',
        password: 'password123',
        password_confirmation: 'different123', # Mismatched
        first_name: 'New',
        last_name: 'User',
        date_of_birth: '1990-01-01',
        phone: '555-555-5555',
        timezone: 'Eastern Time (US & Canada)',
        locale: 'en',
        hearing_disability: true
      } }
    end

    assert_response :unprocessable_entity
    # Check errors directly on the instance variable assigned by the controller
    assert_includes assigns(:user).errors[:password_confirmation], "doesn't match Password"
  end

  def test_should_send_registration_confirmation_email
    # Template should be created by the setup block, no need to create it here again.
    # Clear deliveries to ensure clean state
    ActionMailer::Base.deliveries.clear

    # Create user parameters for registration
    user_params = {
      email: 'testuser@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      first_name: 'Test',
      last_name: 'User',
      date_of_birth: '1990-01-01',
      phone: '555-555-5555',
      timezone: 'Eastern Time (US & Canada)',
      locale: 'en',
      communication_preference: 'email', # Ensure email is sent
      hearing_disability: true,
      vision_disability: false,
      speech_disability: false,
      mobility_disability: false,
      cognition_disability: false
    }

    # Verify a user will be created and one job (the mailer) will be enqueued
    assert_difference('User.count') do
      assert_enqueued_jobs 1 do
        # Create a new user with post request
        post sign_up_path, params: { user: user_params }
      end
    end

    # Now perform the enqueued jobs and check deliveries
    perform_enqueued_jobs
    assert_equal 1, ActionMailer::Base.deliveries.size, 'Email should have been delivered'

    # Verify the registration was successful
    assert_redirected_to welcome_path
    assert_equal 'Account created successfully. Welcome!', flash[:notice]

    # Verify user was created with expected attributes
    user = User.find_by(email: 'testuser@example.com')
    assert_not_nil user, 'User should have been created'
    assert_equal 'Test', user.first_name
    assert_equal 'User', user.last_name
    assert user.hearing_disability

    # Verify the email was sent and has correct attributes
    assert_equal 1, ActionMailer::Base.deliveries.size, 'One email should have been sent'
    email = ActionMailer::Base.deliveries.last

    # Verify email headers
    assert_not_nil email, 'Email should not be nil'
    assert_equal ['no_reply@mdmat.org'], email.from, 'Email should be from no_reply@mdmat.org'
    assert_equal ['testuser@example.com'], email.to, 'Email should be sent to the registered user'
    assert_equal 'Welcome to the Maryland Accessible Telecommunications Program', email.subject
    assert_not email.multipart?, 'Email should not be multipart'

    # Get the email content
    content = email.body.to_s

    # Test that variables were substituted with values
    assert_match(/Test/, content, 'First name should be substituted')
    assert_match(/Test User/, content, 'Full name should be substituted')
    assert_match(%r{constituent_portal/dashboard}, content, 'Should include dashboard link')
    assert_match(%r{constituent_portal/applications/new}, content, 'Should include new application link')
  end
end
