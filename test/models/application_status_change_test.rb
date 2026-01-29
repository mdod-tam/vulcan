# frozen_string_literal: true

require 'test_helper'

class ApplicationStatusChangeTest < ActiveSupport::TestCase
  def setup
    @admin = create(:admin)
    Current.user = @admin
    @constituent = create(:constituent, email: generate(:email))
  end

  def teardown
    Current.reset
  end

  test 'status change creates single ApplicationStatusChange record via callback' do
    application = create(:application, :draft, user: @constituent)

    # Track initial count
    initial_count = ApplicationStatusChange.count

    # Update status directly - callback should handle logging
    application.update!(status: :in_progress)

    # Verify exactly one record was created
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Verify the record has correct data
    change = ApplicationStatusChange.last
    assert_equal 'draft', change.from_status
    assert_equal 'in_progress', change.to_status
    assert_equal @admin.id, change.user_id
  end

  test 'deprecated update_status method creates single record not duplicate' do
    application = create(:application, :draft, user: @constituent)

    # Track initial count
    initial_count = ApplicationStatusChange.count

    # Suppress deprecation warning for test
    Rails.logger.stub :warn, nil do
      # Use deprecated method with user and notes
      application.update_status(:in_progress, user: @admin, notes: 'Test status change')
    end

    # Verify exactly one record was created (not two!)
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Verify the record includes notes from deprecated method
    change = ApplicationStatusChange.last
    assert_equal 'draft', change.from_status
    assert_equal 'in_progress', change.to_status
    assert_equal @admin.id, change.user_id
    assert_equal 'Test status change', change.notes
  end

  test 'auto-approval creates single status change record' do
    # Create application with all proofs attached
    application = create(:application, :in_progress, :with_all_proofs, user: @constituent)

    # First approve income and residency proofs (without medical)
    application.update!(
      income_proof_status: :approved,
      residency_proof_status: :approved
    )

    ApplicationStatusChange.count

    # Now approve medical certification - this should trigger auto-approval
    # because all requirements are now met and the callback checks saved_change_to_*
    application.update!(
      medical_certification_status: :approved
    )

    # Verify exactly one record was created for the auto-approval
    new_records = ApplicationStatusChange.where(
      application: application,
      to_status: 'approved'
    )

    # Should have exactly one auto-approval record
    assert_equal 1, new_records.count
    assert_equal 'Auto-approved based on all requirements being met', new_records.first.notes
  end

  test 'multiple sequential status changes create separate records' do
    application = create(:application, :draft, user: @constituent)

    initial_count = ApplicationStatusChange.count

    # Change 1: draft -> in_progress
    application.update!(status: :in_progress)
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Change 2: in_progress -> awaiting_proof
    application.update!(status: :awaiting_proof)
    assert_equal initial_count + 2, ApplicationStatusChange.count

    # Change 3: awaiting_proof -> in_progress
    application.update!(status: :in_progress)
    assert_equal initial_count + 3, ApplicationStatusChange.count

    # Verify all changes are distinct
    changes = ApplicationStatusChange.where(application: application).order(created_at: :asc)
    assert_equal 3, changes.count
    assert_equal %w[draft in_progress awaiting_proof], changes.map(&:from_status)
    assert_equal %w[in_progress awaiting_proof in_progress], changes.map(&:to_status)
  end

  test 'status change without Current.user falls back to application user' do
    Current.user = nil
    application = create(:application, :draft, user: @constituent)

    initial_count = ApplicationStatusChange.count

    # Update status - should use application.user as fallback
    application.update!(status: :in_progress)

    assert_equal initial_count + 1, ApplicationStatusChange.count
    change = ApplicationStatusChange.last
    assert_equal @constituent.id, change.user_id
  end

  test 'ApplicationStatusChange validation requires all fields' do
    change = ApplicationStatusChange.new
    assert_not change.valid?
    assert_includes change.errors[:from_status], "can't be blank"
    assert_includes change.errors[:to_status], "can't be blank"
    # NOTE: changed_at is automatically set by before_validation callback, so it won't be blank
  end

  test 'changed_at is automatically set if not provided' do
    application = create(:application, :draft, user: @constituent)
    change = ApplicationStatusChange.new(
      application: application,
      user: @admin,
      from_status: 'draft',
      to_status: 'in_progress'
    )

    # Before validation, changed_at should be nil
    assert_nil change.changed_at

    # After validation (which triggers before_validation callback), it should be set
    change.valid?
    assert_not_nil change.changed_at
    assert_instance_of ActiveSupport::TimeWithZone, change.changed_at
  end
end
