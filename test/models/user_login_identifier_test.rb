# frozen_string_literal: true

require 'test_helper'

class UserLoginIdentifierTest < ActiveSupport::TestCase
  test 'find_by_login_identifier is public portal email-backed lookup only' do
    phone = '410-555-0199'
    phone_only = nil
    email_backed = create(:constituent, phone: '410-555-0198')

    Current.paper_context = true
    begin
      phone_only = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'Only',
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

    assert phone_only.portal_access_eligible?
    assert_not phone_only.email_backed_public_portal_account?
    assert_nil User.find_by_login_identifier(phone)

    assert email_backed.email_backed_public_portal_account?
    assert_equal email_backed, User.find_by_login_identifier(email_backed.email)
    assert_equal email_backed, User.find_by_login_identifier(email_backed.phone)
  end

  test 'find_by_login_identifier matches email' do
    user = create(:constituent, email: "login.email.#{SecureRandom.hex(3)}@example.com")

    assert_equal user, User.find_by_login_identifier(user.email)
  end

  test 'find_by_login_identifier matches phone only for email-backed accounts' do
    user = create(:constituent, phone: '410-555-0198')

    assert user.real_email?
    assert_equal user, User.find_by_login_identifier('4105550198')
    assert_equal user, User.find_by_login_identifier(user.phone)
  end

  test 'find_by_login_identifier rejects phone-only records' do
    phone = '410-555-0199'
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'Only',
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

    assert_nil user.email
    assert user.real_phone?
    assert_not user.email_backed_public_portal_account?
    assert_nil User.find_by_login_identifier(phone)
  end

  test 'find_for_account_access sends email delivery for email-shaped contact' do
    user = create(:constituent, email: "access.#{SecureRandom.hex(3)}@example.com")

    found_user, delivery = User.find_for_account_access(user.email)

    assert_equal user, found_user
    assert_equal :email, delivery
  end

  test 'find_for_account_access sends sms for email-backed text phone contact' do
    user = create(:constituent, phone: '410-555-0201', phone_type: 'text')

    found_user, delivery = User.find_for_account_access(user.phone)

    assert_equal user, found_user
    assert_equal :sms, delivery
  end

  test 'find_for_account_access does not deliver for voice phone on email-backed account' do
    user = create(:constituent,
                  phone: '410-555-0202',
                  phone_type: 'voice',
                  email: "voice.#{SecureRandom.hex(3)}@example.com")

    found_user, delivery = User.find_for_account_access(user.phone)

    assert_equal user, found_user
    assert_nil delivery
  end

  test 'find_for_account_access does not match phone-only records' do
    phone = '410-555-0203'
    Current.paper_context = true
    begin
      Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyAccess',
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

    found_user, delivery = User.find_for_account_access(phone)

    assert_nil found_user
    assert_nil delivery
  end

  test 'email_shaped_identifier_does_not_fall_back_to_phone' do
    phone = '410-555-0197'
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'Only',
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

    assert_nil user.email
    assert_nil User.find_by_login_identifier('4105550197@example.com')
    assert_nil User.find_by_login_identifier(phone)
  end

  test 'login_identifier_looks_like_email? treats any at sign as email shaped' do
    assert User.login_identifier_looks_like_email?('  user@example.com  ')
    assert User.login_identifier_looks_like_email?('4105550197@')
  end

  test 'login_identifier_valid_email? requires a valid email shape' do
    assert User.login_identifier_valid_email?('  user@example.com  ')
    assert_not User.login_identifier_valid_email?('4105550197@')
  end

  test 'malformed email shaped identifier does not fall back to phone' do
    phone = '410-555-0195'
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'OnlyMalformed',
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

    assert_nil user.email
    assert_nil User.find_by_login_identifier('4105550195@')
    assert_nil User.find_by_login_identifier(phone)
  end

  test 'find_by_login_identifier rejects placeholder phone' do
    user = create(:constituent, phone: '000-000-1234',
                                email: "placeholder.#{SecureRandom.hex(3)}@example.com")

    assert User.placeholder_phone?(user.phone)
    assert_nil User.find_by_login_identifier(user.phone)
  end

  test 'find_by_login_identifier rejects guardian generated synthetic phone' do
    user = create(:constituent, phone: '000-123-4567',
                                email: "synthetic.#{SecureRandom.hex(3)}@example.com")

    assert User.synthetic_dependent_phone?(user.phone)
    assert User.placeholder_phone?(user.phone)
    assert_nil User.find_by_login_identifier(user.phone)
    assert_nil User.find_by_login_identifier('0001234567')
  end

  test 'find_by_login_identifier rejects system generated email' do
    user = create(:constituent,
                  email: "dependent.#{SecureRandom.hex(3)}@system.matvulcan.local",
                  phone: '410-555-0196',
                  communication_preference: :letter)

    assert User.system_generated_email?(user.email)
    assert_nil User.find_by_login_identifier(user.email)
  end

  test 'find_by_login_identifier rejects dependent synthetic contacts but not guardian real contacts' do
    guardian = create(:constituent, email: "guardian.#{SecureRandom.hex(3)}@example.com", phone: '410-555-0200')
    dependent = create(:constituent,
                       email: "dependent.#{SecureRandom.hex(3)}@system.matvulcan.local",
                       phone: '000-456-7890',
                       dependent_email: guardian.email,
                       dependent_phone: guardian.phone,
                       communication_preference: :email)

    assert_not dependent.portal_access_eligible?
    assert_equal guardian, User.find_by_login_identifier(guardian.email)
    assert_equal guardian, User.find_by_login_identifier(guardian.phone)
    assert_nil User.find_by_login_identifier(dependent.email)
    assert_nil User.find_by_login_identifier(dependent.phone)
  end

  test 'placeholder_phone? handles nil and blank' do
    assert_not User.placeholder_phone?(nil)
    assert_not User.placeholder_phone?('')
  end

  test 'system_generated_email? handles nil and blank' do
    assert_not User.system_generated_email?(nil)
    assert_not User.system_generated_email?('')
  end
end
