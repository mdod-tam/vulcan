# frozen_string_literal: true

require 'test_helper'

class StiUserTest < ActiveSupport::TestCase
  def test_administrator_resolution
    admin = Users::Administrator.create!(
      email: "test-admin-#{Time.now.to_i}@example.com",
      first_name: 'Test',
      last_name: 'Admin',
      password: 'password1234',
      password_confirmation: 'password1234'
    )

    assert_equal Users::Administrator, admin.class

    loaded_admin = User.find(admin.id)
    assert_instance_of Users::Administrator, loaded_admin

    assert loaded_admin.admin?

    admin.destroy
  end

  def test_constituent_resolution
    constituent = Users::Constituent.create!(
      email: "test-constituent-#{Time.now.to_i}@example.com",
      first_name: 'Test',
      last_name: 'Constituent',
      password: 'password1234',
      password_confirmation: 'password1234'
    )

    assert_equal Users::Constituent, constituent.class

    loaded_constituent = User.find(constituent.id)
    assert_instance_of Users::Constituent, loaded_constituent

    assert loaded_constituent.constituent?

    constituent.destroy
  end

  def test_namespaced_sti_type_storage_and_retrieval
    user = create(:user, type: 'Users::Administrator')
    user_id = user.id

    reloaded_user = User.find(user_id)

    assert_equal 'Users::Administrator', reloaded_user.type

    assert_instance_of Users::Administrator, reloaded_user

    user.destroy
  end

  def test_vendor_to_evaluator_transition_without_validation_crossover
    unique_email = "vendor-to-evaluator-test-#{Time.now.to_i}@example.com"
    vendor = create(:vendor_user, email: unique_email)
    assert vendor.valid?, "Starting vendor should be valid: #{vendor.errors.full_messages.join(', ')}"

    vendor.type = 'Users::Evaluator'

    assert vendor.save, "Failed to change type: #{vendor.errors.full_messages.join(', ')}"

    # Use User.find to instantiate the current STI class after the type change.
    reloaded_user = User.find(vendor.id)
    assert_equal 'Users::Evaluator', reloaded_user.type
    assert_instance_of Users::Evaluator, reloaded_user

    vendor.destroy
  end
end
