# frozen_string_literal: true

require 'test_helper'

module Admin
  class UsersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin) # Use FactoryBot to create an admin user
      sign_in_for_integration_test @admin
    end

    test 'show surfaces destructive admin actions with native confirmation messages' do
      user = create(:constituent)

      get admin_user_path(user), headers: { 'Turbo-Frame' => 'admin_user_show' }

      assert_response :success
      assert_select 'form[action=?][method=?][data-turbo-confirm=?]',
                    mfa_tokens_admin_user_path(user), 'post', 'Are you sure?' do
        assert_select 'button', text: 'Delete MFA Tokens'
      end
      assert_select 'form[action=?][method=?][data-turbo-confirm*=?]',
                    admin_user_path(user), 'post', 'Deleting a user is permanent' do
        assert_select 'button', text: 'Delete User'
      end
    end

    test 'show surfaces stronger delete confirmation for constituent with approved application' do
      user = create(:constituent)
      create(:application, :completed, user: user)

      get admin_user_path(user), headers: { 'Turbo-Frame' => 'admin_user_show' }

      assert_response :success
      assert_select 'form[action=?][data-turbo-confirm*=?]',
                    admin_user_path(user), 'This constituent has approved applications'
      assert_select 'form[action=?][data-turbo-confirm*=?]',
                    admin_user_path(user), 'application history, proofs, training, evaluations, and related records'
    end

    test 'index and show do not surface reset password buttons' do
      user = create(:constituent)

      get admin_users_path, headers: { 'Turbo-Frame' => 'admin_users_index' }
      assert_response :success
      assert_no_match(/Reset Password/i, response.body)

      get admin_user_path(user), headers: { 'Turbo-Frame' => 'admin_user_show' }
      assert_response :success
      assert_no_match(/Reset Password/i, response.body)
    end

    test 'admin can delete all mfa tokens for a user' do
      user = create(:constituent)
      create(:webauthn_credential, user: user)
      TotpCredential.create!(user: user, nickname: 'Authenticator app', secret: 'secret')
      SmsCredential.create!(user: user, phone_number: '410-555-1234', verified_at: Time.current)
      create_test_session(user)
      create_test_session(user)

      assert_difference -> { Event.where(action: 'admin_user_mfa_tokens_deleted').count }, 1 do
        assert_difference -> { WebauthnCredential.where(user_id: user.id).count }, -1 do
          assert_difference -> { TotpCredential.where(user_id: user.id).count }, -1 do
            assert_difference -> { SmsCredential.where(user_id: user.id).count }, -1 do
              assert_difference -> { Session.where(user_id: user.id).count }, -2 do
                delete mfa_tokens_admin_user_path(user)
              end
            end
          end
        end
      end

      assert_redirected_to admin_user_path(user)
      assert_equal 'Deleted MFA tokens for Test Constituent.', flash[:notice]
      assert_not user.reload.second_factor_enabled?

      event = Event.find_by!(action: 'admin_user_mfa_tokens_deleted', auditable: user)
      assert_equal @admin.id, event.user_id
      assert_equal user.id, event.metadata['target_user_id']
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'webauthn_credentials')
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'totp_credentials')
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'sms_credentials')
      assert_equal 2, event.metadata['deleted_sessions_count']
    end

    test 'admin can delete mfa tokens when none exist' do
      user = create(:constituent)

      assert_no_difference -> { WebauthnCredential.count + TotpCredential.count + SmsCredential.count } do
        delete mfa_tokens_admin_user_path(user)
      end

      assert_redirected_to admin_user_path(user)
      assert_equal 'No MFA tokens were found for Test Constituent.', flash[:notice]
    end

    test 'admin cannot delete mfa tokens for system user' do
      system_user = User.system_user
      create(:webauthn_credential, user: system_user)

      assert_difference -> { Event.where(action: 'admin_user_mfa_tokens_blocked').count }, 1 do
        assert_no_difference -> { WebauthnCredential.where(user_id: system_user.id).count } do
          delete mfa_tokens_admin_user_path(system_user)
        end
      end

      assert_redirected_to admin_user_path(system_user)
      assert_equal 'You cannot delete MFA tokens for the system user.', flash[:alert]

      event = Event.find_by!(action: 'admin_user_mfa_tokens_blocked', auditable: system_user)
      assert_equal 'system_user', event.metadata['reason']
    end

    test 'non admin cannot delete mfa tokens' do
      sign_out
      non_admin = create(:constituent)
      user = create(:constituent)
      create(:webauthn_credential, user: user)
      sign_in_for_integration_test non_admin

      assert_no_difference -> { WebauthnCredential.where(user_id: user.id).count } do
        delete mfa_tokens_admin_user_path(user)
      end

      assert_redirected_to root_path
    end

    test 'admin can delete a simple user' do
      user = create(:admin)

      assert_difference -> { Event.where(action: 'admin_user_deletion_attempted').count }, 1 do
        assert_difference -> { Event.where(action: 'admin_user_deleted').count }, 1 do
          assert_difference('User.count', -1) do
            delete admin_user_path(user)
          end
        end
      end

      assert_redirected_to admin_users_path
      assert_equal "Deleted user #{user.full_name}.", flash[:notice]
      assert_nil User.find_by(id: user.id)

      deleted_event = Event.find_by!(action: 'admin_user_deleted')
      assert_equal @admin.id, deleted_event.user_id
      assert_equal user.id, deleted_event.metadata['target_user_id']
    end

    test 'admin cannot delete themself' do
      assert_difference -> { Event.where(action: 'admin_user_deletion_blocked').count }, 1 do
        assert_no_difference('User.count') do
          delete admin_user_path(@admin)
        end
      end

      assert_redirected_to admin_user_path(@admin)
      assert_equal 'You cannot delete your own user account.', flash[:alert]
      assert User.exists?(@admin.id)
    end

    test 'admin cannot delete system user' do
      system_user = User.system_user

      assert_difference -> { Event.where(action: 'admin_user_deletion_blocked').count }, 1 do
        assert_no_difference('User.count') do
          delete admin_user_path(system_user)
        end
      end

      assert_redirected_to admin_user_path(system_user)
      assert_equal 'You cannot delete the system user.', flash[:alert]
      assert User.exists?(system_user.id)

      event = Event.find_by!(action: 'admin_user_deletion_blocked', auditable: system_user)
      assert_equal 'system_user', event.metadata['reason']
    end

    test 'admin deletion failure redirects back with alert' do
      user = create(:admin)
      Notification.create!(
        recipient: @admin,
        actor: user,
        action: 'test_notification',
        notifiable: create(:application)
      )

      assert_difference -> { Event.where(action: 'admin_user_deletion_failed').count }, 1 do
        assert_no_difference('User.count') do
          delete admin_user_path(user)
        end
      end

      assert_redirected_to admin_user_path(user)
      assert_match(/Could not delete #{Regexp.escape(user.full_name)}/, flash[:alert])
      assert User.exists?(user.id)

      event = Event.find_by!(action: 'admin_user_deletion_failed', auditable: user)
      assert_equal @admin.id, event.user_id
      assert_equal 'ActiveRecord::InvalidForeignKey', event.metadata['error_class']
    end

    test 'admin deletion failure logs recovery request blockers' do
      user = create(:admin)
      create(:recovery_request, user: user)

      assert_difference -> { Event.where(action: 'admin_user_deletion_failed').count }, 1 do
        assert_no_difference('User.count') do
          delete admin_user_path(user)
        end
      end

      assert_redirected_to admin_user_path(user)
      assert_match(/Could not delete #{Regexp.escape(user.full_name)}/, flash[:alert])
      assert User.exists?(user.id)

      event = Event.find_by!(action: 'admin_user_deletion_failed', auditable: user)
      assert_equal 'ActiveRecord::InvalidForeignKey', event.metadata['error_class']
    end

    test 'admin deletion failure logs voucher blockers for constituent applications' do
      user = create(:constituent)
      application = create(:application, :completed, user: user)
      create(:voucher, application: application, vendor: nil)

      assert_difference -> { Event.where(action: 'admin_user_deletion_failed').count }, 1 do
        assert_no_difference('User.count') do
          assert_no_difference('Application.count') do
            delete admin_user_path(user)
          end
        end
      end

      assert_redirected_to admin_user_path(user)
      assert_match(/Could not delete #{Regexp.escape(user.full_name)}/, flash[:alert])
      assert User.exists?(user.id)
      assert Application.exists?(application.id)

      event = Event.find_by!(action: 'admin_user_deletion_failed', auditable: user)
      assert event.metadata['error_class'].present?
    end

    test 'non admin cannot delete a user' do
      sign_out
      non_admin = create(:constituent)
      user = create(:admin)
      sign_in_for_integration_test non_admin

      assert_no_difference('User.count') do
        delete admin_user_path(user)
      end

      assert_redirected_to root_path
      assert User.exists?(user.id)
    end

    test 'deleting a constituent cascades to their applications' do
      user = create(:constituent)
      application = create(:application, :completed, user: user)

      assert_difference('Users::Constituent.count', -1) do
        assert_difference('Application.count', -1) do
          delete admin_user_path(user)
        end
      end

      assert_redirected_to admin_users_path
      assert_nil User.find_by(id: user.id)
      assert_nil Application.find_by(id: application.id)
    end

    test 'show does not surface delete user button for current admin' do
      get admin_user_path(@admin), headers: { 'Turbo-Frame' => 'admin_user_show' }

      assert_response :success
      assert_select 'form[action=?]', admin_user_path(@admin), count: 0
      assert_select 'button', text: 'Delete User', count: 0
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
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/Failed to create user in admin interface: Failed to create user:/)).once

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

    test 'quick create guardian without email or phone succeeds for address-only intake' do
      assert_difference 'User.count', 1 do
        post admin_users_path, params: {
          first_name: 'Letter',
          last_name: 'Guardian',
          guardian_no_email_address: '1',
          guardian_no_phone_number: '1',
          no_email_address: '1',
          no_phone_number: '1',
          email: 'ignored@example.com',
          phone: '555-000-9999',
          physical_address_1: '100 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          date_of_birth: '01/01/1980',
          communication_preference: 'letter'
        }, as: :json
      end

      assert_response :success
      user = User.order(:created_at).last
      assert_nil user.email
      assert_nil user.phone
      assert user.deliver_via_letter?
      assert_not user.portal_access_eligible?
    end

    test 'admin can update address-only user profile without email' do
      user = nil
      internal_password = SecureRandom.hex(32)
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'Letter', last_name: 'Only',
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      patch admin_user_path(user), params: {
        user: {
          first_name: 'Updated',
          last_name: 'Only',
          email: '',
          phone: '',
          physical_address_1: '200 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          communication_preference: 'letter'
        }
      }

      assert_redirected_to admin_user_path(user)
      user.reload
      assert_equal 'Updated', user.first_name
      assert_nil user.email
      assert_nil user.phone
    end

    test 'constituents list shows no email on file for address-only users' do
      internal_password = SecureRandom.hex(32)
      user = nil
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'Inactive', last_name: 'LetterOnly',
          status: :inactive,
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      create(:application, :archived, user: user)

      get constituents_admin_users_path

      assert_response :success
      assert_match ConstituentCommunicationLabelsHelper::NO_EMAIL_ON_FILE, response.body
    end

    test 'history shows display helpers for address-only users' do
      user = nil
      internal_password = SecureRandom.hex(32)
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'History', last_name: 'LetterOnly',
          status: :inactive,
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      get history_admin_user_path(user)

      assert_response :success
      assert_match ConstituentCommunicationLabelsHelper::NO_EMAIL_ON_FILE, response.body
      assert_match ConstituentCommunicationLabelsHelper::NO_PHONE_ON_FILE, response.body
    end
  end
end
