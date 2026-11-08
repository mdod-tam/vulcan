# frozen_string_literal: true

require 'application_system_test_case'

class RegistrationsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    load_seeded_email_templates('registration_email_verification', 'application_notifications_registration_confirmation')
    ActionMailer::Base.deliveries.clear
  end

  test 'email first registration corrects a rejected password before creating the account' do
    email = "browser-registration-#{SecureRandom.hex(6)}@example.test"
    visit sign_up_path
    assert_no_selector 'input[type=password]'
    assert_no_selector 'input[name="user[phone]"]'
    fill_in 'Email Address', with: 'invalid-address'
    assert_not find('input[name="user[email]"]').evaluate_script('this.checkValidity()')
    fill_in 'Email Address', with: email
    perform_enqueued_jobs { click_button I18n.t('registration_verification.send_link') }
    assert_text I18n.t('registration_verification.check_email')
    assert_nil User.find_by_email(email)
    take_screenshot('registration-email-sent', html: true)

    mail = ActionMailer::Base.deliveries.find { |item| item.to == [email] }
    assert mail, 'The request sends its proof through the mail delivery boundary'
    uri = URI.parse(mail.body.to_s[%r{https?://\S+}])
    visit uri.request_uri
    assert_text I18n.t('registration_verification.complete_title')
    fill_in 'First Name', with: 'Browser'
    fill_in 'Middle Initial', with: 'B'
    fill_in 'Last Name', with: 'Registrant'
    fill_in 'Date of Birth', with: '02/30/1990'
    select 'English', from: 'Language Preference'
    fill_in 'Password', with: 'password1234', exact: true
    fill_in 'Confirm Password', with: 'password5678'
    choose 'pref_letter'
    fill_in 'user_physical_address_1', with: '12 Original Street'
    fill_in 'user_physical_address_2', with: 'Unit 2'
    fill_in 'user_city', with: 'Baltimore'
    select 'Maryland', from: 'user_state'
    fill_in 'user_zip_code', with: '21201'
    check 'newsletter_signup'
    click_button 'Create Account'
    assert_selector '#user_password_confirmation-error'
    assert_field 'First Name', with: 'Browser'
    assert_field 'Middle Initial', with: 'B'
    assert_field 'Last Name', with: 'Registrant'
    assert_field 'Date of Birth', with: '02/30/1990'
    assert_selector '#user_locale option:checked', text: 'English'
    assert_checked_field 'pref_letter'
    assert_checked_field 'newsletter_signup'
    assert_field 'user_physical_address_1', with: '12 Original Street', disabled: false
    assert_field 'user_physical_address_2', with: 'Unit 2', disabled: false
    assert_field 'user_city', with: 'Baltimore', disabled: false
    assert_selector '#user_state option:checked', text: 'Maryland'
    assert_field 'user_zip_code', with: '21201', disabled: false
    assert_nil User.find_by_email(email)
    take_screenshot('registration-completion-validation', html: true)

    fill_in 'First Name', with: 'Corrected'
    fill_in 'Middle Initial', with: 'C'
    fill_in 'Last Name', with: 'Applicant'
    fill_in 'Date of Birth', with: '02/16/1991'
    select 'Spanish', from: 'Language Preference'
    assert_selector '#user_locale option:checked', text: 'Spanish'
    fill_in 'Password', with: 'password1234', exact: true
    fill_in 'Confirm Password', with: 'password1234'
    choose 'pref_email'
    assert_selector '#address_fields[aria-hidden=true]', visible: :all
    assert_selector '#user_physical_address_1[disabled]', visible: :all
    choose 'pref_letter'
    assert_field 'user_physical_address_1', with: '12 Original Street', disabled: false
    assert_selector '#user_physical_address_1[required][aria-required=true]'
    fill_in 'user_physical_address_1', with: '24 Corrected Street'
    fill_in 'user_physical_address_2', with: 'Unit 4'
    fill_in 'user_city', with: 'Arlington'
    select 'Virginia', from: 'user_state'
    fill_in 'user_zip_code', with: '22201'
    choose 'pref_email'
    assert_selector '#user_physical_address_1[disabled]', visible: :all
    choose 'pref_letter'
    assert_field 'user_physical_address_1', with: '24 Corrected Street', disabled: false
    assert_field 'user_physical_address_2', with: 'Unit 4', disabled: false
    assert_field 'user_city', with: 'Arlington', disabled: false
    assert_selector '#user_state option:checked', text: 'Virginia'
    assert_field 'user_zip_code', with: '22201', disabled: false
    uncheck 'newsletter_signup'
    take_screenshot('registration-corrected-letter-address', html: true, full: true)
    click_button 'Create Account'
    assert_current_path welcome_path
    user = User.find_by_email(email)
    assert user&.authenticate('password1234')
    assert_nil user.phone
    assert_equal 'Corrected', user.first_name
    assert_equal 'C', user.middle_initial
    assert_equal 'Applicant', user.last_name
    assert_equal Date.new(1991, 2, 16), user.date_of_birth
    assert_equal 'es', user.locale
    assert_equal 'letter', user.communication_preference
    assert_equal '24 Corrected Street', user.physical_address_1
    assert_equal 'Unit 4', user.physical_address_2
    assert_equal 'Arlington', user.city
    assert_equal 'VA', user.state
    assert_equal '22201', user.zip_code
    assert_not user.newsletter_signup
    assert RegistrationVerification.order(:id).last.consumed_at
    take_screenshot('registration-completed', html: true)
  end

  test 'expired email link returns to a usable initiation form in Spanish' do
    verification = RegistrationVerification.create!(email: 'expired-browser@example.test', locale: 'es', expires_at: 1.minute.ago)
    visit edit_registration_verification_path(token: verification.proof_token, locale: 'es')
    assert_text I18n.t('registration_verification.invalid_link', locale: :es)
    assert_selector 'input[name="user[email]"]'
    assert_no_selector 'input[type=password]'
    take_screenshot('registration-expired-es', html: true)
  end
end
