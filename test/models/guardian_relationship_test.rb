# frozen_string_literal: true

require 'test_helper'

class GuardianRelationshipTest < ActiveSupport::TestCase
  setup do
    @guardian = create(:constituent, email: 'guardian@example.com', phone: '1234567890')
    @dependent = create(:constituent, email: 'dependent@example.com', phone: '0987654321')
  end

  test 'should be valid with all required attributes' do
    relationship = GuardianRelationship.new(
      guardian_user: @guardian,
      dependent_user: @dependent,
      relationship_type: 'Parent'
    )
    assert(relationship.valid?, "Expected relationship to be valid, but got errors: #{relationship.errors.full_messages.join(', ')}")
  end

  test 'should not be valid without a guardian_user' do
    relationship = GuardianRelationship.new(
      dependent_user: @dependent,
      relationship_type: 'Parent'
    )
    assert_not(relationship.valid?, 'Expected relationship to be invalid without a guardian_user')
    assert_includes(relationship.errors[:guardian_user], 'must exist')
  end

  test 'should not be valid without a dependent_user' do
    relationship = GuardianRelationship.new(
      guardian_user: @guardian,
      relationship_type: 'Parent'
    )
    assert_not(relationship.valid?, 'Expected relationship to be invalid without a dependent_user')
    assert_includes(relationship.errors[:dependent_user], 'must exist')
  end

  test 'should not be valid without a relationship_type' do
    relationship = GuardianRelationship.new(
      guardian_user: @guardian,
      dependent_user: @dependent
    )
    assert_not(relationship.valid?, 'Expected relationship to be invalid without a relationship_type')
    assert_includes(relationship.errors[:relationship_type], "can't be blank")
  end

  test 'should enforce uniqueness of guardian_id and dependent_id pair' do
    GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: @dependent,
      relationship_type: 'Parent'
    )
    duplicate_relationship = GuardianRelationship.new(
      guardian_user: @guardian,
      dependent_user: @dependent,
      relationship_type: 'Legal Guardian' # Type can be different, pair must be unique
    )
    assert_not(duplicate_relationship.valid?, 'Expected duplicate relationship to be invalid')
    # Assuming the unique index is on guardian_id and dependent_id in the database,
    # Rails might report this as an error on :guardian_id or :dependent_id depending on implementation.
    # A common way is an error on one of the fields, e.g., :dependent_id "has already been taken".
    # Or a custom validation might add to :base.
    # For this example, let's assume a general uniqueness error message.
    # If using a custom validation message:
    # assert_includes duplicate_relationship.errors[:base], "Guardian and dependent relationship already exists"
    # If relying on DB index and default Rails message (often on the second field in index):
    assert(duplicate_relationship.errors[:dependent_id].any? || duplicate_relationship.errors[:guardian_id].any?,
           'Expected an error on dependent_id or guardian_id for uniqueness')
  end

  test 'guardian_user association should work' do
    relationship = GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: @dependent,
      relationship_type: 'Parent'
    )
    assert_equal(@guardian, relationship.guardian_user)
  end

  test 'dependent_user association should work' do
    relationship = GuardianRelationship.create!(
      guardian_user: @guardian,
      dependent_user: @dependent,
      relationship_type: 'Parent'
    )
    assert_equal(@dependent, relationship.dependent_user)
  end

  # The replay pair's integrity guarantees live in the database, not only in the writer. These pin
  # them directly: application code could regress without either constraint being noticed by the
  # controller tests, which always travel the happy path.

  test 'a portal creation key cannot be stored without its fingerprint' do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: @dependent,
                                   relationship_type: 'Parent', portal_creation_key: SecureRandom.hex(16))
    end
    assert_match(/portal_creation_pair_check/, error.message)
  end

  test 'a fingerprint cannot be stored without its key' do
    error = assert_raises(ActiveRecord::StatementInvalid) do
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: @dependent,
                                   relationship_type: 'Parent', portal_creation_fingerprint: 'v1:abc')
    end
    assert_match(/portal_creation_pair_check/, error.message)
  end

  test 'one guardian cannot spend the same creation key twice' do
    key = SecureRandom.hex(16)
    GuardianRelationship.create!(guardian_user: @guardian, dependent_user: @dependent,
                                 relationship_type: 'Parent', portal_creation_key: key,
                                 portal_creation_fingerprint: 'v1:abc')

    assert_raises(ActiveRecord::RecordNotUnique) do
      GuardianRelationship.create!(guardian_user: @guardian, dependent_user: create(:constituent),
                                   relationship_type: 'Parent', portal_creation_key: key,
                                   portal_creation_fingerprint: 'v1:def')
    end
  end

  # The index is scoped, so the same raw key is a different request under a different guardian.
  test 'two guardians may each spend the same raw creation key' do
    key = SecureRandom.hex(16)
    2.times do
      GuardianRelationship.create!(guardian_user: create(:constituent), dependent_user: create(:constituent),
                                   relationship_type: 'Parent', portal_creation_key: key,
                                   portal_creation_fingerprint: 'v1:abc')
    end

    assert_equal 2, GuardianRelationship.where(portal_creation_key: key).count
  end

  # Rows written by paper and admin intake carry neither half, which the partial index permits.
  test 'many relationships may carry no creation key at all' do
    2.times do
      GuardianRelationship.create!(guardian_user: create(:constituent), dependent_user: create(:constituent),
                                   relationship_type: 'Parent')
    end

    assert_equal 2, GuardianRelationship.where(portal_creation_key: nil).count
  end
end
