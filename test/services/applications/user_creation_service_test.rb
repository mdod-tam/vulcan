# frozen_string_literal: true

require 'test_helper'

module Applications
  class UserCreationServiceTest < ActiveSupport::TestCase
    setup do
      setup_paper_application_context
    end

    teardown do
      teardown_paper_application_context
    end

    test 'finds existing user by phone when email is absent' do
      existing = nil
      Current.paper_context = true
      begin
        existing = Users::Constituent.create!(
          first_name: 'Existing', last_name: 'PhoneOnly',
          phone: "410-555-#{SecureRandom.random_number(9000) + 1000}",
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

      Current.paper_context = true
      begin
        result = UserCreationService.new(
          { first_name: 'Other', last_name: 'Person', phone: existing.phone, hearing_disability: '1' },
          is_managing_adult: true,
          skip_email_validation: true
        ).call
      ensure
        Current.reset
      end

      assert result.success?
      assert_equal existing, result.data[:user]
    end

    test 'does not reuse unrelated user by phone when primary email is system-generated' do
      existing_phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      existing = nil
      Current.paper_context = true
      begin
        existing = Users::Constituent.create!(
          first_name: 'Existing', last_name: 'PhoneHolder',
          phone: existing_phone, phone_type: 'voice',
          email: "existing-#{SecureRandom.hex(4)}@example.com",
          physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1980, 1, 1),
          password: 'password123', password_confirmation: 'password123',
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      attrs = {
        first_name: 'Child', last_name: 'Dependent',
        email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
        dependent_email: "guardian-#{SecureRandom.hex(4)}@example.com",
        phone: existing_phone,
        dependent_phone: existing_phone,
        date_of_birth: Date.new(2015, 1, 1),
        physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        hearing_disability: '1'
      }

      service = UserCreationService.new(attrs)
      found = service.send(:find_existing_user)

      assert_nil found, 'Expected no user lookup when primary email is system-generated'

      Current.paper_context = true
      begin
        result = service.call
      ensure
        Current.reset
      end

      assert_not result.success?, 'Duplicate primary phone should not reuse an existing user'
      assert_not_equal existing, result.data[:user]
    end

    test 'find_existing_user returns existing user without creating duplicate' do
      phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      existing = create(:constituent, email: "existing-#{SecureRandom.hex(4)}@example.com", phone: phone)

      Current.paper_context = true
      begin
        result = UserCreationService.new(
          {
            first_name: 'Other',
            last_name: 'Person',
            email: existing.email,
            phone: existing.phone,
            physical_address_1: '123 Main St',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1'
          },
          is_managing_adult: true
        ).call
      ensure
        Current.reset
      end

      assert result.success?
      assert result.data[:existing_user]
      assert_equal existing.id, result.data[:user].id
      assert_nil result.data[:temp_password]
    end

    test 'reusing phone-only existing user requires explicit no_email_address flag' do
      phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      Current.paper_context = true
      begin
        existing = UserCreationService.new(
          phone_only_attrs(phone),
          is_managing_adult: true,
          skip_email_validation: true,
          skip_user_lookup: true
        ).call.data[:user]

        result = UserCreationService.new(
          phone_only_attrs(phone).merge(first_name: existing.first_name, last_name: existing.last_name),
          is_managing_adult: true
        ).call

        assert_not result.success?
        assert_includes result.message, 'Email is required'
      ensure
        Current.reset
      end
    end

    test 'creates portal-eligible phone-only user with temp password' do
      phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"

      Current.paper_context = true
      begin
        result = UserCreationService.new(
          phone_only_attrs(phone),
          is_managing_adult: true,
          skip_email_validation: true,
          skip_user_lookup: true
        ).call
      ensure
        Current.reset
      end

      assert result.success?
      user = result.data[:user]
      assert_nil user.email
      assert user.phone.present?
      assert user.portal_access_eligible?
      assert result.data[:temp_password].present?
      assert user.force_password_change?
    end

    test 'creates portal-eligible user when email has surrounding whitespace' do
      phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      email = " padded-#{SecureRandom.hex(4)}@example.com "

      Current.paper_context = true
      begin
        result = UserCreationService.new(
          phone_only_attrs(phone).merge(email: email),
          is_managing_adult: true,
          skip_user_lookup: true
        ).call
      ensure
        Current.reset
      end

      assert result.success?
      user = result.data[:user]
      assert_equal email.strip.downcase, user.email
      assert user.portal_access_eligible?
      assert result.data[:temp_password].present?
    end

    test 'creates address-only user without temp password' do
      Current.paper_context = true
      begin
        result = UserCreationService.new(
          address_only_attrs,
          is_managing_adult: true,
          skip_email_validation: true,
          skip_phone_validation: true,
          skip_user_lookup: true
        ).call
      ensure
        Current.reset
      end

      assert result.success?
      user = result.data[:user]
      assert_nil user.email
      assert_nil user.phone
      assert_not user.portal_access_eligible?
      assert_nil result.data[:temp_password]
      assert_not user.force_password_change?
      assert user.deliver_via_letter?
    end

    test 'requires phone for managing adult when no_phone flag is not set' do
      Current.paper_context = true
      begin
        result = UserCreationService.new(
          address_only_attrs.merge(email: "phone-required-#{SecureRandom.hex(4)}@example.com"),
          is_managing_adult: true,
          skip_user_lookup: true
        ).call
      ensure
        Current.reset
      end

      assert_not result.success?
      assert_includes result.data[:errors].join, 'Phone number is required'
    end

    test 'requires phone when no_email flag is set but no_phone flag is not' do
      Current.paper_context = true
      begin
        result = UserCreationService.new(
          address_only_attrs,
          is_managing_adult: true,
          skip_email_validation: true,
          skip_user_lookup: true
        ).call
      ensure
        Current.reset
      end

      assert_not result.success?
      assert_includes result.data[:errors].join, 'Phone number is required'
    end

    private

    def phone_only_attrs(phone)
      {
        first_name: 'Phone',
        last_name: 'Only',
        phone: phone,
        phone_type: 'voice',
        communication_preference: 'letter',
        physical_address_1: '123 Main St',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        date_of_birth: Date.new(1950, 1, 1),
        hearing_disability: '1'
      }
    end

    def address_only_attrs
      {
        first_name: 'Letter',
        last_name: 'Only',
        communication_preference: 'letter',
        physical_address_1: '456 Oak Ave',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21202',
        date_of_birth: Date.new(1960, 5, 5),
        hearing_disability: '1'
      }
    end
  end
end
