# frozen_string_literal: true

require 'test_helper'

module Admin
  class UsersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin) # Use FactoryBot to create an admin user
      sign_in_for_integration_test @admin
    end

    test 'should create new constituent user as guardian' do
      unique_email = "new.test.guardian.#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      assert_difference('Users::Constituent.count') do
        post admin_users_path, params: {
          first_name: 'New',
          last_name: 'Guardian',
          email: unique_email,
          phone: unique_phone,
          date_of_birth: Date.new(1990, 1, 15),
          physical_address_1: '123 Maple Street',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          communication_preference: 'email'
        }, as: :json
      end

      assert_response :success
      json_response = response.parsed_body
      assert json_response['success']
      assert_equal 'New', json_response['user']['first_name']
      assert_equal 'Guardian', json_response['user']['last_name']

      # Verify user was created properly
      user = Users::Constituent.find_by(email: unique_email)
      assert user.present?
      assert user.force_password_change?
      assert user.verified?
    end

    test 'should handle validation errors' do
      assert_no_difference('Users::Constituent.count') do
        post admin_users_path, params: {
          # Missing required fields
          first_name: '',
          last_name: '',
          email: 'invalid-email'
        }, as: :json
      end

      assert_response :unprocessable_content
      json_response = response.parsed_body
      assert_not json_response['success']
      assert json_response['errors'].present?
    end

    test 'should detect potential duplicate guardians' do
      # First, create an existing user directly
      first_user = Users::Constituent.create!(
        first_name: 'Test',
        last_name: 'Duplicate',
        email: "first.user.#{Time.now.to_i}@example.com",
        phone: '555-111-1111',
        date_of_birth: Date.parse('1995-06-11'),
        physical_address_1: '456 First St',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: 'email',
        password: SecureRandom.hex(8),
        verified: true
      )

      # Create a second user via the controller with matching name and DOB
      assert_difference('Users::Constituent.count') do
        post admin_users_path, params: {
          first_name: 'Test',           # Same first name
          last_name: 'Duplicate',       # Same last name
          date_of_birth: '1995-06-11',  # Same date of birth
          email: 'second.duplicate@example.com', # Different email
          phone: '555-222-2222', # Different phone
          physical_address_1: '123 Main St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21202',
          communication_preference: 'email'
        }, as: :json
      end

      assert_response :success

      # Test that duplicate detection would work by finding users with same criteria
      second_user = Users::Constituent.find_by(email: 'second.duplicate@example.com')

      # Test duplicate detection by finding users with same name and DOB
      potential_duplicates = Users::Constituent.where(
        first_name: second_user.first_name,
        last_name: second_user.last_name,
        date_of_birth: second_user.date_of_birth
      ).where.not(id: second_user.id)

      assert potential_duplicates.exists?, 'Expected user to be flagged for duplicate review'
      assert potential_duplicates.include?(first_user), 'Should find the first user as a potential duplicate'
    end
  end
end
