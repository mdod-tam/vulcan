# frozen_string_literal: true

require 'test_helper'

class UserTest < ActiveSupport::TestCase
  setup do
    # Use a unique test run identifier to avoid collisions with existing data
    # This avoids the need to delete existing users and prevents foreign key violations
    @test_run_id = SecureRandom.hex(4)

    # Create constituent users for all tests with unique phone numbers in valid 10-digit format
    # Using a "777-" prefix to avoid collision with "555-" prefixed phones in fixtures.
    @existing_constituent = create(:constituent,
                                   email: "unique.constituent.#{@test_run_id}@example.com",
                                   phone: "777-111-#{1000 + (@test_run_id.to_i(16) % 9000)}")

    # Create users for guardian relationship tests with unique phone numbers
    @guardian_user = create(:constituent,
                            email: "guardian.user.#{@test_run_id}@example.com",
                            phone: "777-222-#{2000 + (@test_run_id.to_i(16) % 8000)}")
    @dependent_user1 = create(:constituent,
                              email: "dependent.user1.#{@test_run_id}@example.com",
                              phone: "777-333-#{3000 + (@test_run_id.to_i(16) % 7000)}")
    @dependent_user2 = create(:constituent,
                              email: "dependent.user2.#{@test_run_id}@example.com",
                              phone: "777-444-#{4000 + (@test_run_id.to_i(16) % 6000)}")
    @another_guardian = create(:constituent,
                               email: "another.guardian.#{@test_run_id}@example.com",
                               phone: "777-555-#{5000 + (@test_run_id.to_i(16) % 5000)}")
  end

  test 'admins scope works as expected' do
    # Just verify the scope SQL structure is what we expect
    scope_sql = User.admins.to_sql
    assert_match(/WHERE.+"users"\."type" = 'Users::Administrator'/, scope_sql)
  end

  test 'should not save constituent with duplicate email' do
    constituent = build(:constituent, email: @existing_constituent.email) # Same email as @existing_constituent
    assert_not constituent.save, 'Saved constituent with duplicate email'
    assert_includes constituent.errors[:email], 'has already been taken'
  end

  test 'should save constituent with unique email' do
    constituent = build(:constituent, email: "another.constituent.#{SecureRandom.hex(4)}@example.com")
    assert constituent.save, "Did not save constituent with unique email: #{constituent.errors.full_messages.join(', ')}"
  end

  test 'should not save constituent with duplicate phone number' do
    constituent = build(:constituent, phone: @existing_constituent.phone) # Same phone as @existing_constituent
    assert_not constituent.save, 'Saved constituent with duplicate phone number'
    assert_includes constituent.errors[:phone], 'has already been taken'
  end

  test 'should save constituent with unique phone number' do
    # Generate a valid 10-digit phone number format
    valid_phone = "555-333-#{rand(1000..9999)}"
    constituent = build(:constituent, phone: valid_phone)
    assert constituent.save, "Did not save constituent with unique phone number: #{constituent.errors.full_messages.join(', ')}"
  end

  test 'should save constituent with blank phone number' do
    constituent = build(:constituent, phone: '')
    assert constituent.save, "Did not save constituent with blank phone number: #{constituent.errors.full_messages.join(', ')}"
  end

  test 'should save multiple constituents with blank phone numbers' do
    create(:constituent, phone: nil) # First constituent with nil phone
    constituent2 = build(:constituent, phone: '') # Second constituent with blank phone
    assert constituent2.save, "Did not save second constituent with blank phone number: #{constituent2.errors.full_messages.join(', ')}"
  end

  test 'phone number formatting runs before validation' do
    # Create unformatted phone matching existing_constituent's phone but in a different format
    unformatted_phone = @existing_constituent.phone.gsub('-', '.')
    constituent = build(:constituent, phone: unformatted_phone)

    assert_not constituent.save, 'Saved constituent with unformatted but duplicate phone number'
    assert_includes constituent.errors[:phone], 'has already been taken', 'Phone formatting did not run before uniqueness validation'
    assert_equal @existing_constituent.phone, constituent.phone, 'Phone number was not formatted correctly'
  end

  # --- Guardian/Dependent Relationship Tests ---

  test 'a user can have many dependents' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user2, relationship_type: 'Parent')

    assert_equal(2, @guardian_user.dependents.count)
    assert_includes(@guardian_user.dependents, @dependent_user1)
    assert_includes(@guardian_user.dependents, @dependent_user2)
  end

  test 'a user can have many guardians' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    GuardianRelationship.create!(guardian_user: @another_guardian, dependent_user: @dependent_user1, relationship_type: 'Legal Guardian')

    assert_equal(2, @dependent_user1.guardians.count)
    assert_includes(@dependent_user1.guardians, @guardian_user)
    assert_includes(@dependent_user1.guardians, @another_guardian)
  end

  test 'dependents association returns empty for a user with no dependents' do
    assert_empty(@dependent_user1.dependents)
  end

  test 'guardians association returns empty for a user with no guardians' do
    assert_empty(@guardian_user.guardians)
  end

  test 'guardian? returns true if user has dependents' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    assert(@guardian_user.guardian?)
  end

  test 'guardian? returns false if user has no dependents' do
    assert_not(@dependent_user1.guardian?) # A dependent is not a guardian in this context
    assert_not(create(:constituent).guardian?) # A new user is not a guardian
  end

  test 'dependent? returns true if user has guardians' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    assert(@dependent_user1.dependent?)
  end

  test 'dependent? returns false if user has no guardians' do
    assert_not(@guardian_user.dependent?) # A guardian is not a dependent in this context
    assert_not(create(:constituent).dependent?) # A new user is not a dependent
  end

  test 'destroying a guardian user destroys their guardian_relationships_as_guardian' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    assert_difference('GuardianRelationship.count', -1) do
      @guardian_user.destroy
    end
  end

  test 'destroying a dependent user destroys their guardian_relationships_as_dependent' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    assert_difference('GuardianRelationship.count', -1) do
      @dependent_user1.destroy
    end
  end

  # --- Authorization Method Tests (Rails-centric pattern) ---

  test 'editable_by_guardian scope returns only dependents of the specified guardian' do
    # Set up relationships
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user2, relationship_type: 'Parent')
    GuardianRelationship.create!(guardian_user: @another_guardian, dependent_user: @dependent_user1, relationship_type: 'Legal Guardian')

    # Guardian should see their dependents
    # Use .to_a to materialize the grouped results
    dependents = User.editable_by_guardian(@guardian_user).to_a
    assert_equal 2, dependents.length
    assert_includes dependents, @dependent_user1
    assert_includes dependents, @dependent_user2

    # Another guardian should only see their dependent
    other_dependents = User.editable_by_guardian(@another_guardian).to_a
    assert_equal 1, other_dependents.length
    assert_includes other_dependents, @dependent_user1
  end

  test 'accessible_by_guardian scope works same as editable_by_guardian' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    editable = User.editable_by_guardian(@guardian_user)
    accessible = User.accessible_by_guardian(@guardian_user)

    assert_equal editable.to_a, accessible.to_a
  end

  test 'editable_by_guardian? returns true for guardian of dependent' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    assert @dependent_user1.editable_by_guardian?(@guardian_user)
  end

  test 'editable_by_guardian? returns false for non-guardian' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    # Another guardian who is not related to this dependent
    assert_not @dependent_user1.editable_by_guardian?(@another_guardian)
  end

  test 'editable_by_guardian? returns false for user who is not a dependent' do
    # Guardian user is not a dependent, so editable_by_guardian? should return false
    assert_not @guardian_user.editable_by_guardian?(@another_guardian)
  end

  test 'editable_by_guardian? returns false for nil user' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    assert_not @dependent_user1.editable_by_guardian?(nil)
  end

  test 'accessible_by_guardian? works same as editable_by_guardian?' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    assert_equal @dependent_user1.editable_by_guardian?(@guardian_user),
                 @dependent_user1.accessible_by_guardian?(@guardian_user)
    assert_equal @dependent_user1.editable_by_guardian?(@another_guardian),
                 @dependent_user1.accessible_by_guardian?(@another_guardian)
  end

  test 'viewable_by_guardian? works same as accessible_by_guardian?' do
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')

    assert_equal @dependent_user1.accessible_by_guardian?(@guardian_user),
                 @dependent_user1.viewable_by_guardian?(@guardian_user)
  end

  test 'multiple guardians can both edit same dependent' do
    # Set up shared dependent
    GuardianRelationship.create!(guardian_user: @guardian_user, dependent_user: @dependent_user1, relationship_type: 'Parent')
    GuardianRelationship.create!(guardian_user: @another_guardian, dependent_user: @dependent_user1, relationship_type: 'Legal Guardian')

    # Both guardians should be able to edit
    assert @dependent_user1.editable_by_guardian?(@guardian_user)
    assert @dependent_user1.editable_by_guardian?(@another_guardian)

    # Both should see the dependent in their scope
    assert_includes User.editable_by_guardian(@guardian_user), @dependent_user1
    assert_includes User.editable_by_guardian(@another_guardian), @dependent_user1
  end

  # --- Profile Change Audit Logging Tests ---

  test 'logs profile update when user updates their own profile' do
    # Clear Current.user to simulate self-update
    Current.user = nil

    # Store the original values before update
    original_first_name = @existing_constituent.first_name
    original_email = @existing_constituent.email

    assert_difference('Event.count', 1) do
      @existing_constituent.update!(first_name: 'Updated Name', email: 'updated@example.com')
    end

    event = Event.last
    assert_equal 'profile_updated', event.action
    assert_equal @existing_constituent.id, event.user_id
    assert_equal @existing_constituent.id, event.metadata['user_id']
    assert_equal @existing_constituent.id, event.metadata['updated_by']

    # Check that changes are recorded
    changes = event.metadata['changes']
    assert_equal 'Updated Name', changes['first_name']['new']
    assert_equal original_first_name, changes['first_name']['old']
    assert_equal 'updated@example.com', changes['email']['new']
    assert_equal original_email, changes['email']['old']
  end

  test 'logs profile update when guardian updates dependent profile' do
    # Set Current.user to guardian to simulate guardian update
    Current.user = @guardian_user
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

    assert_difference('Event.count', 1) do
      @dependent_user1.update!(first_name: 'Updated Dependent', phone: unique_phone)
    end

    event = Event.last
    assert_equal 'profile_updated_by_guardian', event.action
    assert_equal @guardian_user.id, event.user_id # Actor is the guardian
    assert_equal @dependent_user1.id, event.metadata['user_id'] # Target is the dependent
    assert_equal @guardian_user.id, event.metadata['updated_by']

    # Check that changes are recorded
    changes = event.metadata['changes']
    assert_equal 'Updated Dependent', changes['first_name']['new']
    assert_equal unique_phone, changes['phone']['new']
  end

  test 'does not log event when no profile fields change' do
    # Update a non-profile field
    assert_no_difference('Event.count') do
      @existing_constituent.update!(status: :suspended)
    end
  end

  test 'does not log event when profile fields change but no actual changes occur' do
    # Update with same values
    assert_no_difference('Event.count') do
      @existing_constituent.update!(
        first_name: @existing_constituent.first_name,
        email: @existing_constituent.email
      )
    end
  end

  test 'logs multiple field changes in single event' do
    Current.user = nil

    # Generate unique values to avoid conflicts
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    unique_email = "newemail.#{SecureRandom.hex(4)}@example.com"

    assert_difference('Event.count', 1) do
      @existing_constituent.update!(
        first_name: 'New First',
        last_name: 'New Last',
        email: unique_email,
        phone: unique_phone,
        physical_address_1: '123 New Street',
        city: 'New City',
        state: 'NY',
        zip_code: '12345'
      )
    end

    event = Event.last
    changes = event.metadata['changes']

    # Verify all changed fields are recorded
    assert_equal 'New First', changes['first_name']['new']
    assert_equal 'New Last', changes['last_name']['new']
    assert_equal unique_email, changes['email']['new']
    assert_equal unique_phone, changes['phone']['new']
    assert_equal '123 New Street', changes['physical_address_1']['new']
    assert_equal 'New City', changes['city']['new']
    assert_equal 'NY', changes['state']['new']
    assert_equal '12345', changes['zip_code']['new']
  end

  test 'saved_changes_to_profile_fields? returns true when profile fields change' do
    @existing_constituent.first_name = 'Changed Name'
    @existing_constituent.save!

    assert @existing_constituent.send(:saved_changes_to_profile_fields?)
  end

  test 'saved_changes_to_profile_fields? returns false when no profile fields change' do
    @existing_constituent.status = :suspended
    @existing_constituent.save!

    assert_not @existing_constituent.send(:saved_changes_to_profile_fields?)
  end

  test 'profile change event includes timestamp' do
    Current.user = nil

    freeze_time do
      @existing_constituent.update!(first_name: 'Timestamped Update')

      event = Event.last
      assert_equal Time.current.iso8601, event.metadata['timestamp']
    end
  end

  test 'handles nil values in profile changes' do
    # Set a field to nil - use a unique phone number to avoid conflicts
    unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"
    @existing_constituent.update!(phone: unique_phone) # Set initial value

    Current.user = nil
    assert_difference('Event.count', 1) do
      @existing_constituent.update!(phone: nil)
    end

    event = Event.last
    changes = event.metadata['changes']
    assert_equal unique_phone, changes['phone']['old']
    assert_nil changes['phone']['new']
  end

  test 'handles blank to value changes' do
    # Start with blank value
    user = create(:constituent, physical_address_1: nil)

    Current.user = nil
    assert_difference('Event.count', 1) do
      user.update!(physical_address_1: '123 Main St')
    end

    event = Event.last
    changes = event.metadata['changes']
    assert_nil changes['physical_address_1']['old']
    assert_equal '123 Main St', changes['physical_address_1']['new']
  end

  teardown do
    # Clean up Current.user to avoid affecting other tests
    Current.user = nil
  end
end
