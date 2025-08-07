# frozen_string_literal: true

require 'test_helper'

class PasswordsControllerTest < ActionDispatch::IntegrationTest
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
  end

  def test_should_update_password_with_valid_inputs
    patch password_path, params: {
      password_challenge: 'password123',
      password: 'NewValid*Password123',
      password_confirmation: 'NewValid*Password123'
    }

    assert_redirected_to sign_in_path
    follow_redirect!
    assert_equal 'Password successfully updated.', flash[:notice]

    # Verify password was actually changed
    @user.reload
    assert_not_equal @original_password_digest, @user.password_digest
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
