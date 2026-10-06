# frozen_string_literal: true

require 'test_helper'

class UserEncryptedValidationTest < ActiveSupport::TestCase
  def unique_attributes
    {
      first_name: 'John',
      last_name: 'Doe',
      email: "test_#{SecureRandom.hex(8)}@example.com",
      phone: "555-#{format('%03d', rand(100..999))}-#{format('%04d', rand(1000..9999))}",
      password: 'password1234',
      type: 'Users::Constituent',
      hearing_disability: true,
      ssn_last4: '1234',
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    }
  end

  def data_encrypted_in_database?(user)
    # Read raw columns to avoid transparent decryption.
    raw_data = User.connection.select_one(
      "SELECT email, phone FROM users WHERE id = #{user.id}"
    )

    raw_data['email'] != user.email || raw_data['phone'] != user.phone
  rescue StandardError
    false
  end

  test 'creates a user with readable email, phone, and SSN values' do
    attrs = unique_attributes
    user = User.create!(attrs)

    assert user.persisted?
    assert_equal attrs[:email], user.email
    assert_equal attrs[:phone], user.phone
    assert_equal attrs[:ssn_last4], user.ssn_last4

    if data_encrypted_in_database?(user)
      puts 'At least one raw contact column differs from its readable attribute value'
    else
      puts 'Raw contact comparison did not establish a storage difference'
    end
  end

  test 'validates email uniqueness with encrypted data' do
    attrs = unique_attributes

    _user1 = User.create!(attrs)

    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    user2 = User.new(attrs.merge(phone: unique_phone))

    assert_not user2.valid?
    assert_includes user2.errors[:email], 'has already been taken'
  end

  test 'validates phone uniqueness with encrypted data' do
    attrs = unique_attributes

    _user1 = User.create!(attrs)

    user2 = User.new(attrs.merge(email: 'different@example.com'))

    assert_not user2.valid?
    assert_includes user2.errors[:phone], 'has already been taken'
  end

  test 'accepts distinct email and phone values after an existing constituent' do
    attrs = unique_attributes

    _guardian = User.create!(attrs)

    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    dependent = User.new(attrs.merge(
                           phone: unique_phone,
                           email: 'dependent@example.com'
                         ))

    assert dependent.valid?, "User should be valid with distinct contact values: #{dependent.errors.full_messages}"
  end

  test 'database constraint prevents duplicates when validation is bypassed' do
    attrs = unique_attributes

    _user1 = User.create!(attrs)

    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    duplicate_attrs = attrs.merge(phone: unique_phone)

    assert_raises(ActiveRecord::RecordNotUnique) do
      duplicate_user = User.new(duplicate_attrs)
      duplicate_user.save!(validate: false)
    end
  end

  test 'system_user method works with encryption' do
    ensure_system_audit_actor!

    system_user = User.system_user

    assert system_user.persisted?
    assert_equal 'system@mdmat.org', system_user.email
    assert_equal 'Users::Administrator', system_user.type
    assert system_user.admin?
  end

  test 'system_user method returns same user on subsequent calls' do
    ensure_system_audit_actor!

    user1 = User.system_user
    user2 = User.system_user

    assert_equal user1.id, user2.id
  end

  test 'find_by locates the user by encrypted email and phone' do
    attrs = unique_attributes
    user = User.create!(attrs)

    found_by_email = User.find_by(email: attrs[:email])
    assert_not_nil found_by_email, 'Should find user by email'
    assert_equal user.id, found_by_email.id

    found_by_phone = User.find_by(phone: attrs[:phone])
    assert_not_nil found_by_phone, 'Should find user by phone'
    assert_equal user.id, found_by_phone.id
  end

  test 'exists_with_email helper method works correctly' do
    attrs = unique_attributes
    _user = User.create!(attrs)

    assert User.exists_with_email?(attrs[:email]), 'Should find existing user by email'
    assert_not User.exists_with_email?('nonexistent@example.com'), 'Should not find non-existent user'
  end

  test 'exists_with_phone helper method works correctly' do
    attrs = unique_attributes
    _user = User.create!(attrs)

    assert User.exists_with_phone?(attrs[:phone]), 'Should find existing user by phone'
    assert_not User.exists_with_phone?('555-999-9999'), 'Should not find non-existent user'
  end

  test 'contact validations do not raise when find_by is stubbed to fail' do
    attrs = unique_attributes
    user = User.new(attrs)

    User.stub :find_by, -> { raise ActiveRecord::StatementInvalid, 'test error' } do
      assert_nothing_raised do
        user.send(:email_must_be_unique)
        user.send(:phone_must_be_unique)
      end
    end
  end

  test 'encryption keys and query options are configured' do
    assert Rails.application.config.active_record.encryption.primary_key.present?,
           'Primary encryption key should be configured'
    assert Rails.application.config.active_record.encryption.deterministic_key.present?,
           'Deterministic encryption key should be configured'

    assert_equal false, Rails.application.config.active_record.encryption.extend_queries,
                 'extend_queries should be disabled'
    assert_equal true, Rails.application.config.active_record.encryption.support_unencrypted_data,
                 'support_unencrypted_data should be enabled'

    puts '✓ Encryption configuration verified'
  end

  test 'declares the expected encrypted attributes' do
    encrypted_attrs = User.encrypted_attributes.map(&:name)
    expected_attrs = %w[email phone ssn_last4 password_digest date_of_birth
                        physical_address_1 physical_address_2 city state zip_code]

    expected_attrs.each do |attr|
      assert_includes encrypted_attrs, attr, "#{attr} should be declared as encrypted"
    end

    puts "✓ All expected attributes declared as encrypted: #{encrypted_attrs.join(', ')}"
  end

  test 'encrypted data is queryable with standard Rails methods' do
    attrs = unique_attributes
    user = User.create!(attrs)

    found_user = User.find_by(email: attrs[:email])
    assert_equal user.id, found_user.id if found_user

    found_user = User.find_by(phone: attrs[:phone])
    assert_equal user.id, found_user.id if found_user

    users = User.where(email: attrs[:email])
    assert_includes users.pluck(:id), user.id
  end

  test 'created user exposes submitted contact, SSN, and address values and authenticates' do
    attrs = unique_attributes
    user = User.create!(attrs)

    assert_equal attrs[:email], user.email
    assert_equal attrs[:phone], user.phone
    assert_equal attrs[:ssn_last4], user.ssn_last4
    assert_equal attrs[:physical_address_1], user.physical_address_1
    assert_equal attrs[:city], user.city
    assert_equal attrs[:state], user.state
    assert_equal attrs[:zip_code], user.zip_code

    # encrypts protects the BCrypt digest at rest. Authentication still compares the supplied password.
    assert user.authenticate('password1234')
  end

  test 'data remains accessible after reload' do
    attrs = unique_attributes
    user = User.create!(attrs)
    original_id = user.id

    user.reload

    assert_equal attrs[:email], user.email
    assert_equal attrs[:phone], user.phone
    assert_equal attrs[:ssn_last4], user.ssn_last4
    assert_equal original_id, user.id
  end

  test 'email and phone queries complete without raising' do
    attrs = unique_attributes
    _user = User.create!(attrs)

    assert_nothing_raised do
      User.find_by(email: attrs[:email])
      User.find_by(phone: attrs[:phone])
      User.exists_with_email?(attrs[:email])
      User.exists_with_phone?(attrs[:phone])
    end

    puts 'Email and phone queries completed without raising'
  end

  test 'nil and blank profile values remain accessible' do
    user = User.new(unique_attributes.merge(
                      physical_address_2: nil,
                      middle_initial: '',
                      county_of_residence: nil
                    ))
    user.save!

    assert_nil user.physical_address_2
    assert_equal '', user.middle_initial
    assert_nil user.county_of_residence
  end
end
