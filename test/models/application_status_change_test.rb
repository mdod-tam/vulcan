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

  test 'transition_status! creates single ApplicationStatusChange record' do
    application = create(:application, :draft, user: @constituent)

    # Track initial count
    initial_count = ApplicationStatusChange.count

    # Update status via transition_status!
    application.transition_status!(:in_progress, actor: @admin, metadata: { trigger: 'test' })

    # Verify exactly one record was created
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Verify the record has correct data
    change = ApplicationStatusChange.last
    assert_equal 'draft', change.from_status
    assert_equal 'in_progress', change.to_status
    assert_equal @admin.id, change.user_id
  end

  test 'transition_status! method creates single record with notes' do
    application = create(:application, :draft, user: @constituent)

    # Track initial count
    initial_count = ApplicationStatusChange.count

    # Use transition_status! with user and notes
    application.transition_status!(:in_progress, actor: @admin, notes: 'Test status change', metadata: { trigger: 'test' })

    # Verify exactly one record was created
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Verify the record includes notes
    change = ApplicationStatusChange.last
    assert_equal 'draft', change.from_status
    assert_equal 'in_progress', change.to_status
    assert_equal @admin.id, change.user_id
    assert_equal 'Test status change', change.notes
  end

  test 'reconciler auto-approval creates single status change record with metadata' do
    application = create(:application, :in_progress, :with_all_proofs, user: @constituent)

    application.update_columns(
      income_proof_status: Application.income_proof_statuses[:approved],
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:approved]
    )
    application.reload

    initial_count = ApplicationStatusChange.where(application: application, to_status: 'approved').count

    application.reconcile_workflow_state!(actor: @admin, trigger: :test)

    new_records = ApplicationStatusChange.where(application: application, to_status: 'approved')
    assert_equal initial_count + 1, new_records.count

    record = new_records.last
    assert_equal 'Auto-approved based on all requirements being met', record.notes
    assert_equal 'auto_approval', record.metadata['trigger']
    assert_equal 0, Event.where(auditable: application, action: 'application_auto_approved').count
  end

  test 'multiple sequential status changes create separate records' do
    application = create(:application, :draft, user: @constituent)

    initial_count = ApplicationStatusChange.count

    # Change 1: draft -> in_progress
    application.transition_status!(:in_progress, actor: @admin, metadata: { trigger: 'test' })
    assert_equal initial_count + 1, ApplicationStatusChange.count

    # Change 2: in_progress -> awaiting_proof
    application.transition_status!(:awaiting_proof, actor: @admin, metadata: { trigger: 'test' })
    assert_equal initial_count + 2, ApplicationStatusChange.count

    # Change 3: awaiting_proof -> in_progress
    application.transition_status!(:in_progress, actor: @admin, metadata: { trigger: 'test' })
    assert_equal initial_count + 3, ApplicationStatusChange.count

    # Verify all changes are distinct
    changes = ApplicationStatusChange.where(application: application).order(created_at: :asc)
    assert_equal 3, changes.count
    assert_equal %w[draft in_progress awaiting_proof], changes.map(&:from_status)
    assert_equal %w[in_progress awaiting_proof in_progress], changes.map(&:to_status)
  end

  test 'status change attributes actor explicitly without Current.user' do
    Current.user = nil
    application = create(:application, :draft, user: @constituent)

    initial_count = ApplicationStatusChange.count

    # Update status via transition_status!
    application.transition_status!(:in_progress, actor: @constituent, metadata: { trigger: 'test' })

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
