# frozen_string_literal: true

require 'test_helper'

class DuplicateDetectionServiceTest < ActiveSupport::TestCase
  setup do
    @registration_attrs = {
      email: 'new-signup@example.com',
      phone: '555-123-4567',
      phone_type: 'voice',
      first_name: 'New',
      last_name: 'Applicant',
      date_of_birth: '1990-01-01',
      physical_address_1: '123 Main St',
      zip_code: '21201'
    }
  end

  test 'email-backed duplicate returns redirect_sign_in outcome' do
    existing = create(:constituent, email: 'existing-portal@example.com')

    result = detect(:public_registration, @registration_attrs.merge(email: existing.email))

    assert result.success?
    data = result.data
    assert data.hard_block
    assert_equal :redirect_sign_in, data.public_outcome
    assert_includes data.reasons, 'exact_email'
    assert_equal [existing], data.matched_users
  end

  test 'synthetic email duplicate returns support_only outcome' do
    synthetic_email = "dependent-#{SecureRandom.hex(4)}@system.matvulcan.local"
    existing = create(:constituent, email: synthetic_email, phone: '410-555-0101', phone_type: 'text')

    result = detect(:public_registration, @registration_attrs.merge(email: synthetic_email))

    assert result.success?
    data = result.data
    assert data.hard_block
    assert_equal :support_only, data.public_outcome
    assert_includes data.reasons, 'exact_email_non_portal'
    assert_equal [existing], data.matched_users
  end

  test 'phone-only paper record collision returns support_only outcome' do
    phone = '410-555-0199'
    existing = nil
    Current.paper_context = true
    begin
      existing = Users::Constituent.create!(
        first_name: 'Paper', last_name: 'Only',
        email: nil,
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

    result = detect(:public_registration, @registration_attrs.merge(email: 'unique-phone-conflict@example.com', phone: phone))

    assert result.success?
    data = result.data
    assert data.hard_block
    assert_equal :support_only, data.public_outcome
    assert_includes data.reasons, 'exact_phone'
    assert_equal [existing], data.matched_users
  end

  test 'email duplicate takes precedence when phone matches different account' do
    email_user = create(:constituent, email: 'email-precedence@example.com')
    phone_user = create(:constituent, email: "other-#{SecureRandom.hex(3)}@example.com", phone: '555-987-6543')

    result = detect(
      :public_registration,
      @registration_attrs.merge(email: email_user.email, phone: phone_user.phone)
    )

    assert result.success?
    data = result.data
    assert_equal :redirect_sign_in, data.public_outcome
    assert_includes data.reasons, 'exact_email'
    assert_includes data.reasons, 'email_phone_split'
  end

  test 'name and dob soft match flags without hard block' do
    existing = create(:constituent,
                      first_name: 'Soft',
                      last_name: 'Match',
                      date_of_birth: Date.new(1985, 5, 5),
                      physical_address_1: '999 Other Rd',
                      zip_code: '21401',
                      email: "soft-match-#{SecureRandom.hex(3)}@example.com")

    result = detect(
      :public_registration,
      @registration_attrs.merge(
        email: "different-#{SecureRandom.hex(3)}@example.com",
        phone: '555-444-3333',
        first_name: existing.first_name,
        last_name: existing.last_name,
        date_of_birth: existing.date_of_birth
      )
    )

    assert result.success?
    data = result.data
    assert_not data.hard_block
    assert_equal :flag, data.recommended_action
    assert_includes data.reasons, 'name_dob'
    assert_not_includes data.reasons, 'address_zip'
    assert_includes data.matched_users.map(&:id), existing.id
  end

  test 'matching address and zip strengthens soft duplicate score' do
    existing = create(:constituent,
                      first_name: 'Address',
                      last_name: 'Match',
                      date_of_birth: Date.new(1982, 2, 2),
                      physical_address_1: '123 Main St',
                      zip_code: '21201',
                      email: "address-match-#{SecureRandom.hex(3)}@example.com")

    result = detect(
      :public_registration,
      @registration_attrs.merge(
        email: "different-#{SecureRandom.hex(3)}@example.com",
        phone: '555-444-3333',
        first_name: existing.first_name,
        last_name: existing.last_name,
        date_of_birth: existing.date_of_birth,
        physical_address_1: '123 Main Street',
        zip_code: '21201'
      )
    )

    assert result.success?
    data = result.data
    assert_equal :flag, data.recommended_action
    assert_includes data.reasons, 'name_dob'
    assert_includes data.reasons, 'address_zip'
    assert_equal DuplicateDetectionService::SCORE_NAME_DOB + DuplicateDetectionService::SCORE_ADDRESS_ZIP, data.score
  end

  test 'non matching address does not add address zip reason' do
    existing = create(:constituent,
                      first_name: 'Different',
                      last_name: 'Address',
                      date_of_birth: Date.new(1983, 3, 3),
                      physical_address_1: '999 Other Rd',
                      zip_code: '21401',
                      email: "different-address-#{SecureRandom.hex(3)}@example.com")

    result = detect(
      :public_registration,
      @registration_attrs.merge(
        email: "unique-#{SecureRandom.hex(3)}@example.com",
        phone: '555-444-3333',
        first_name: existing.first_name,
        last_name: existing.last_name,
        date_of_birth: existing.date_of_birth,
        physical_address_1: '123 Main St',
        zip_code: '21201'
      )
    )

    assert result.success?
    data = result.data
    assert_equal :flag, data.recommended_action
    assert_includes data.reasons, 'name_dob'
    assert_not_includes data.reasons, 'address_zip'
    assert_equal DuplicateDetectionService::SCORE_NAME_DOB, data.score
  end

  test 'paper address only intake flags address only record when address matches' do
    existing = nil
    Current.paper_context = true
    begin
      existing = Users::Constituent.create!(
        first_name: 'Paper',
        last_name: 'AddressOnly',
        email: nil,
        phone: nil,
        communication_preference: :letter,
        physical_address_1: '456 Oak Ave',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21202',
        date_of_birth: Date.new(1975, 6, 6),
        password: 'password123',
        password_confirmation: 'password123',
        hearing_disability: true
      )
    ensure
      Current.reset
    end

    result = detect(
      :paper_new_self,
      {
        email: nil,
        phone: nil,
        first_name: existing.first_name,
        last_name: existing.last_name,
        date_of_birth: existing.date_of_birth,
        physical_address_1: '456 Oak Avenue',
        zip_code: '21202'
      }
    )

    assert result.success?
    data = result.data
    assert_equal :flag, data.recommended_action
    assert_includes data.reasons, 'name_dob'
    assert_includes data.reasons, 'address_zip'
    assert_includes data.reasons, 'address_only_record'
    assert_includes data.matched_users.map(&:id), existing.id
  end

  test 'no match allows registration to proceed' do
    result = detect(:public_registration, @registration_attrs.merge(email: "unique-#{SecureRandom.hex(4)}@example.com"))

    assert result.success?
    data = result.data
    assert_not data.hard_block
    assert_equal :allow, data.recommended_action
    assert_equal :proceed, data.public_outcome
    assert_empty data.reasons
  end

  test 'failed validation path does not mutate anything through service alone' do
    assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
      result = detect(:public_registration, email: '', phone: '', first_name: '', last_name: '')
      assert result.success?
      assert_not result.data.hard_block
    end
  end

  test 'paper intake detects exact email collision without public redirect outcome' do
    existing = create(:constituent, email: 'paper-intake-dup@example.com')

    result = detect(
      :paper_new_self,
      @registration_attrs.merge(
        email: existing.email,
        phone: '555-999-8888'
      )
    )

    assert result.success?
    data = result.data
    assert data.hard_block
    assert_includes data.reasons, 'exact_email'
    assert_equal :proceed, data.public_outcome
    assert_equal :block, data.recommended_action
  end

  test 'admin create detects exact phone collision without public support copy outcome' do
    phone = '410-555-0177'
    create(:constituent, email: "phone-admin-#{SecureRandom.hex(3)}@example.com", phone: phone, phone_type: 'text')

    result = detect(
      :admin_create,
      @registration_attrs.merge(
        email: "new-admin-#{SecureRandom.hex(3)}@example.com",
        phone: phone
      )
    )

    assert result.success?
    data = result.data
    assert data.hard_block
    assert_includes data.reasons, 'exact_phone'
    assert_equal :proceed, data.public_outcome
  end

  test 'hard block outcomes from duplicate detection create no workflow records' do
    existing = create(:constituent, email: 'blocked-email@example.com')

    assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
      result = detect(:public_registration, @registration_attrs.merge(email: existing.email))
      assert result.success?
      assert result.data.hard_block
    end
  end

  test 'support_only synthetic email collision creates no workflow records' do
    synthetic_email = "dependent-#{SecureRandom.hex(4)}@system.matvulcan.local"
    create(:constituent, email: synthetic_email, phone: '410-555-0102', phone_type: 'text')

    assert_no_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
      result = detect(:public_registration, @registration_attrs.merge(email: synthetic_email))
      assert result.success?
      assert_equal :support_only, result.data.public_outcome
    end
  end

  private

  def detect(context, attrs)
    DuplicateDetectionService.new(context: context, attrs: attrs).call
  end
end
