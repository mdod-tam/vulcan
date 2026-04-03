# frozen_string_literal: true

require 'test_helper'

class ApplicationTransitionStatusTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @other_admin = create(:admin)
    @constituent = create(:constituent, email: generate(:email))
    Current.reset
  end

  teardown do
    Current.reset
  end

  test 'transition_status! creates one status change and event with explicit actor, notes, and metadata' do
    application = create(:application, :in_progress, user: @constituent)
    Current.user = @other_admin

    assert_difference -> { ApplicationStatusChange.where(application: application).count }, 1 do
      assert_difference -> { Event.where(auditable: application, action: 'application_status_changed').count }, 1 do
        assert application.transition_status!(
          :approved,
          actor: @admin,
          notes: 'Manual approval',
          metadata: { trigger: 'admin_panel' }
        )
      end
    end

    application.reload
    assert_equal 'approved', application.status

    change = ApplicationStatusChange.where(application: application).order(:created_at).last
    assert_equal 'in_progress', change.from_status
    assert_equal 'approved', change.to_status
    assert_equal @admin, change.user
    assert_equal 'Manual approval', change.notes

    event = Event.where(auditable: application, action: 'application_status_changed').order(:created_at).last
    assert_equal @admin, event.user
    assert_equal 'in_progress', event.metadata['old_status']
    assert_equal 'approved', event.metadata['new_status']
    assert_equal 'Manual approval', event.metadata['notes']
    assert_equal 'admin_panel', event.metadata['trigger']
  end

  test 'transition_status! is a no-op when the target status matches the current status' do
    application = create(:application, :approved, user: @constituent)

    assert_no_difference -> { ApplicationStatusChange.where(application: application).count } do
      assert_no_difference -> { Event.where(auditable: application, action: 'application_status_changed').count } do
        assert application.transition_status!(:approved, actor: @admin)
      end
    end

    application.reload
    assert_equal 'approved', application.status
  end

  test 'transition_status! requires an explicit actor' do
    application = create(:application, :in_progress, user: @constituent)

    error = assert_raises(ArgumentError) do
      application.transition_status!(:approved, actor: nil)
    end

    assert_equal 'actor is required', error.message
  end

  test 'transition_status! rolls back the status change if status audit logging fails' do
    application = create(:application, :in_progress, user: @constituent)

    AuditEventService.stub :log, ->(**) { raise 'status audit failed' } do
      error = assert_raises(RuntimeError) do
        application.transition_status!(:approved, actor: @admin)
      end

      assert_equal 'status audit failed', error.message
    end

    application.reload
    assert_equal 'in_progress', application.status
    assert_equal 0, ApplicationStatusChange.where(application: application, to_status: 'approved').count
    assert_equal 0, Event.where(auditable: application, action: 'application_status_changed').count
  end
end
