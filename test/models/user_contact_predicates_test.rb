# frozen_string_literal: true

require 'test_helper'

class UserContactPredicatesTest < ActiveSupport::TestCase
  test 'real_email? is true for valid non-synthetic email' do
    user = build(:constituent, email: 'real@example.com')

    assert user.real_email?
  end

  test 'real_email? is false for blank email' do
    user = build(:constituent, email: nil)

    assert_not user.real_email?
  end

  test 'real_email? is false for system generated email' do
    user = build(:constituent, email: 'dependent-abc@system.matvulcan.local')

    assert_not user.real_email?
  end

  test 'real_email? is false for invalid email format' do
    user = build(:constituent, email: 'not-an-email')

    assert_not user.real_email?
  end

  test 'real_phone? is true for valid non-synthetic phone' do
    user = build(:constituent, phone: '410-555-0100')

    assert user.real_phone?
  end

  test 'real_phone? is false for blank phone' do
    user = build(:constituent, phone: nil)

    assert_not user.real_phone?
  end

  test 'real_phone? is false for synthetic dependent phone' do
    user = build(:constituent, phone: '000-123-4567')

    assert_not user.real_phone?
  end

  test 'real_phone? is false for invalid phone format' do
    user = build(:constituent, phone: '12345')

    assert_not user.real_phone?
  end

  test 'sms_capable_phone? requires real phone and text phone type' do
    text_user = build(:constituent, phone: '410-555-0101', phone_type: 'text')
    voice_user = build(:constituent, phone: '410-555-0102', phone_type: 'voice')

    assert text_user.sms_capable_phone?
    assert_not voice_user.sms_capable_phone?
  end

  test 'sms_capable_phone? is false for synthetic phone even when text type' do
    user = build(:constituent, phone: '000-000-5678', phone_type: 'text')

    assert_not user.sms_capable_phone?
  end

  test 'portal_access_eligible? is true with real email only' do
    user = build(:constituent, email: 'portal@example.com', phone: nil)

    assert user.portal_access_eligible?
  end

  test 'email_backed_public_portal_account? requires real email' do
    assert build(:constituent, email: 'portal@example.com').email_backed_public_portal_account?
    assert_not build(:constituent, email: nil, phone: '410-555-0103').email_backed_public_portal_account?
  end

  test 'mfa_account_name prefers real email then phone then name' do
    email_user = build(:constituent, email: 'mfa@example.com', phone: '410-555-0104')
    assert_equal 'mfa@example.com', email_user.mfa_account_name

    phone_user = build(:constituent, email: nil, phone: '410-555-0105', first_name: 'Pat', last_name: 'Lee')
    assert_equal '410-555-0105', phone_user.mfa_account_name
  end

  test 'portal_access_eligible? is true with real phone only' do
    user = build(:constituent, email: nil, phone: '410-555-0103')

    assert user.portal_access_eligible?
  end

  test 'portal_access_eligible? is false for address-only user' do
    user = build(:constituent, email: nil, phone: nil)

    assert_not user.portal_access_eligible?
  end

  test 'portal_access_eligible? is false for synthetic contacts only' do
    user = build(:constituent,
                 email: 'dependent-abc@system.matvulcan.local',
                 phone: '000-123-4567')

    assert_not user.portal_access_eligible?
  end

  test 'portal_phone_only_without_email? allows password update without email' do
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Phone', last_name: 'Only',
        phone: '410-555-0310',
        phone_type: 'voice',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true,
        force_password_change: true
      )
    ensure
      Current.reset
    end

    assert_nil user.email
    assert user.send(:email_optional?)

    assert user.update(password: 'newpassword123', password_confirmation: 'newpassword123', force_password_change: false)
  end

  test 'email is required for new portal signup even with phone present' do
    user = Users::Constituent.new(
      first_name: 'Phone', last_name: 'Only',
      phone: '410-555-0311',
      phone_type: 'voice',
      date_of_birth: Date.new(1990, 1, 1),
      password: 'password123', password_confirmation: 'password123',
      hearing_disability: true
    )

    assert_not user.send(:email_optional?)
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  test 'address_only_contact? allows persisted address-only user updates without email' do
    user = nil
    Current.paper_context = true
    begin
      user = Users::Constituent.create!(
        first_name: 'Letter', last_name: 'Only',
        communication_preference: :letter,
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        date_of_birth: Date.new(1960, 1, 1),
        password: 'password123', password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    assert user.send(:address_only_contact?)
    assert user.send(:email_optional?)
    assert user.update(first_name: 'Updated')
    assert_not user.update(email: 'not-an-email')
    assert_includes user.errors[:email], 'is invalid'
  end

  test 'email_optional? is false for persisted address-only staff users' do
    staff = create(:admin, email: generate(:email), phone: '410-555-0188')
    staff.update_columns(email: nil, phone: nil)

    assert staff.send(:address_only_contact?)
    assert_not staff.send(:email_optional?)
  end
end
