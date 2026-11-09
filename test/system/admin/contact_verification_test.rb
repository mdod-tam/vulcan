# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ContactVerificationTest < ApplicationSystemTestCase
    test 'staff contact verification retains an incomplete record and permits a corrected voice contact' do
      load_seeded_email_templates('contact_change_verification', 'contact_change_notice')
      admin = create(:admin)
      credential = admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
      user = create(:constituent)
      original_version = user.security_version
      original_profile = user.attributes.slice('first_name', 'last_name', 'email', 'phone', 'phone_type', 'date_of_birth',
                                               'physical_address_1', 'physical_address_2', 'city', 'state', 'zip_code',
                                               'communication_preference', 'newsletter_signup')
      target_session = Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'Existing target session',
                                       reauthenticated_at: Time.current, reauthenticated_security_version: user.security_version)
      pending = Users::ContactChange.new(user: user, actor: user, session: target_session, token: target_session.session_token)
                                    .request!(kind: 'phone', proposed_value: '240-555-0195', phone_type: 'voice')
      retained_values = {
        'user_first_name' => 'Retained', 'user_last_name' => 'Profile',
        'user_email' => "retained-contact-#{SecureRandom.hex(5)}@example.test", 'user_phone' => '240-555-0196',
        'user_date_of_birth' => 'invalid-date', 'user_physical_address_1' => '200 Retained Road',
        'user_physical_address_2' => 'Suite 3', 'user_city' => 'Alexandria', 'user_state' => 'VA', 'user_zip_code' => '22314'
      }
      corrected_values = {
        'user_first_name' => 'Corrected', 'user_last_name' => 'Contact',
        'user_email' => "corrected-contact-#{SecureRandom.hex(5)}@example.test", 'user_phone' => '240-555-0197',
        'user_date_of_birth' => '03/04/1982', 'user_physical_address_1' => '300 Corrected Avenue',
        'user_physical_address_2' => 'Apartment 4', 'user_city' => 'Baltimore', 'user_state' => 'MD', 'user_zip_code' => '21202'
      }

      visit sign_in_path
      fill_in 'contact-input', with: admin.email
      fill_in 'password-input', with: 'password1234'
      click_button I18n.t('sessions.form.submit')
      assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
      fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
      click_button I18n.t('two_factor_verification.common.submit')
      assert_current_path admin_dashboard_path

      visit admin_user_path(user)
      click_link 'Edit User'
      assert_current_path edit_admin_user_path(user)
      assert_text "Pending phone request: #{pending.proposed_value}"
      assert_field 'user_phone', with: user.phone
      assert_selector '#user_date_of_birth[required]'
      take_screenshot('staff-contact-verification-pending-hint', html: true, full: true)
      retained_values.each { |field, value| fill_in field, with: value }
      choose 'Videophone'
      choose 'admin_user_comm_pref_email'
      check 'admin_user_newsletter_signup'
      check 'Identity verified using the approved process'
      check 'Association with the new contact verified'
      fill_in 'Verification method', with: 'x'
      fill_in 'Nonsecret case reference or rationale', with: 'xx'
      click_button 'Update User'

      assert_text 'Contact changes require another administrator'
      retained_values.each { |field, value| assert_field field, with: value }
      assert_checked_field 'Videophone'
      assert_checked_field 'admin_user_comm_pref_email'
      assert_checked_field 'admin_user_newsletter_signup'
      assert_checked_field 'Identity verified using the approved process'
      assert_checked_field 'Association with the new contact verified'
      assert_field 'Verification method', with: 'x'
      assert_field 'Nonsecret case reference or rationale', with: 'xx'
      assert_equal original_profile, user.reload.attributes.slice(*original_profile.keys)
      assert_equal original_version, user.security_version
      assert user.sessions.exists?
      assert pending.reload.pending?
      assert_button 'Update User', disabled: false
      take_screenshot('staff-contact-verification-error-retains-input', html: true, full: true)

      uncheck 'Identity verified using the approved process'
      uncheck 'Association with the new contact verified'
      click_button 'Update User'
      assert_text 'Contact changes require another administrator'
      assert_unchecked_field 'Identity verified using the approved process'
      assert_unchecked_field 'Association with the new contact verified'
      retained_values.each { |field, value| assert_field field, with: value }
      assert_checked_field 'admin_user_newsletter_signup'
      assert_equal original_profile, user.reload.attributes.slice(*original_profile.keys)
      take_screenshot('staff-contact-verification-unchecked-refusal', html: true, full: true)

      corrected_values.each { |field, value| fill_in field, with: value }
      choose 'Text/SMS'
      assert_checked_field 'Text/SMS'
      choose 'Voice'
      assert_checked_field 'Voice'
      choose 'Mailed Letter'
      assert_checked_field 'Mailed Letter'
      uncheck 'admin_user_newsletter_signup'
      assert_unchecked_field 'admin_user_newsletter_signup'
      assert_selector 'input[type=hidden][name="user[newsletter_signup]"][value="0"]', visible: :all
      fill_in 'Verification method', with: 'Corrected approved non-SMS check'
      fill_in 'Nonsecret case reference or rationale', with: 'CASE-BROWSER-CORRECTED-456'
      check 'Identity verified using the approved process'
      check 'Association with the new contact verified'
      assert_checked_field 'Identity verified using the approved process'
      assert_checked_field 'Association with the new contact verified'
      corrected_values.each { |field, value| assert_field field, with: value }
      assert_button 'Update User', disabled: false
      take_screenshot('staff-contact-verification-corrected', html: true, full: true)
      click_button 'Update User'

      assert_current_path admin_user_path(user)
      user.reload
      corrected_values.except('user_date_of_birth').each do |field, value|
        assert_equal value, user.public_send(field.delete_prefix('user_'))
      end
      assert_equal Date.new(1982, 3, 4), user.date_of_birth
      assert_equal 'voice', user.phone_type
      assert user.deliver_via_letter?
      assert_not user.newsletter_signup?
      assert_equal original_version + 2, user.security_version
      assert_empty user.sessions
      assert admin.sessions.exists?
      assert pending.reload.canceled_at
      changes = ContactChangeRequest.where(user_id: user.id).where.not(completed_at: nil)
      assert_equal %w[email phone], changes.order(:kind).pluck(:kind)
      assert_equal corrected_values.fetch('user_email'), changes.find_by!(kind: 'email').proposed_value
      assert_equal corrected_values.fetch('user_phone'), changes.find_by!(kind: 'phone').proposed_value
      events = Event.where(action: 'account_contact_change_completed', auditable: user)
      assert_equal 2, events.count
      events.each do |event|
        assert_equal 'Corrected approved non-SMS check', event.metadata.dig('verification', 'method')
        assert_equal 'CASE-BROWSER-CORRECTED-456', event.metadata.dig('verification', 'reference')
        assert_equal true, event.metadata.dig('verification', 'identity_verified')
        assert_equal true, event.metadata.dig('verification', 'new_contact_association_verified')
      end
      take_screenshot('staff-contact-verification-completed', html: true, full: true)
    end
  end
end
