# frozen_string_literal: true

require 'test_helper'

class ApplicationTransitionStatusTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    clear_performed_jobs
    @admin = create(:admin)
    @other_admin = create(:admin)
    @constituent = create(:constituent, email: generate(:email))
    Current.reset
  end

  teardown do
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    FeatureFlag.disable!(:vouchers_enabled)
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

  test 'transition_status! enqueues initial voucher issuance on real approval transition' do
    with_after_commit_callbacks do
      admin = create(:admin)
      constituent = create(:constituent, email: generate(:email))
      application = create(:application, :in_progress, :voucher_fulfillment, user: constituent)

      assert_enqueued_with(job: IssueInitialVoucherJob, args: [application.id, admin.id, 'manual_approval']) do
        assert application.transition_status!(:approved, actor: admin)
      end
    end
  end

  test 'transition_status! does not enqueue initial voucher issuance for equipment fulfillment' do
    with_after_commit_callbacks do
      admin = create(:admin)
      constituent = create(:constituent, email: generate(:email))
      application = create(:application, :in_progress, user: constituent)

      assert application.equipment_fulfillment?
      assert_no_enqueued_jobs only: IssueInitialVoucherJob do
        assert application.transition_status!(:approved, actor: admin)
      end
    end
  end

  test 'transition_status! creates automatic voucher through issue job after approval commit' do
    with_after_commit_callbacks do
      FeatureFlag.enable!(:vouchers_enabled)
      admin = create(:admin)
      constituent = create(:constituent, email: generate(:email))
      application = create(:application, :in_progress, :voucher_fulfillment, user: constituent)
      application.update_columns(
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        id_proof_status: Application.id_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved]
      )

      assert_difference -> { Voucher.where(application: application).count }, 1 do
        assert_difference -> { Event.where(action: 'voucher_assigned', auditable_type: 'Voucher').count }, 1 do
          perform_enqueued_jobs(only: IssueInitialVoucherJob) do
            assert application.transition_status!(:approved, actor: admin)
          end
        end
      end

      voucher = Voucher.find_by!(application: application)
      event = Event.find_by!(auditable: voucher, action: 'voucher_assigned')

      assert_equal 'manual_approval', event.metadata['assignment_method']
      assert_equal voucher.id, event.metadata['voucher_id']
      assert_equal voucher.issued_at.iso8601, event.metadata['issued_at']
    end
  end

  test 'approval status persists when initial voucher job fails' do
    with_after_commit_callbacks do
      FeatureFlag.enable!(:vouchers_enabled)
      admin = create(:admin)
      constituent = create(:constituent, email: generate(:email))
      application = create(:application, :in_progress, :voucher_fulfillment, user: constituent)
      application.update_columns(
        income_proof_status: Application.income_proof_statuses[:approved],
        residency_proof_status: Application.residency_proof_statuses[:approved],
        id_proof_status: Application.id_proof_statuses[:approved],
        medical_certification_status: Application.medical_certification_statuses[:approved]
      )

      application.transition_status!(:approved, actor: admin)

      Application.any_instance.stubs(:assign_voucher!).raises(StandardError, 'voucher write failed')
      assert_enqueued_jobs 1, only: IssueInitialVoucherJob do
        assert_no_difference -> { Voucher.where(application: application).count } do
          IssueInitialVoucherJob.perform_now(application.id, admin.id)
        end
      end

      application.reload
      assert_equal 'approved', application.status
      assert_equal 1, ApplicationStatusChange.where(application: application, to_status: 'approved').count
      assert_equal 0, Voucher.where(application: application).count
    ensure
      Application.any_instance.unstub(:assign_voucher!)
    end
  end

  test 'transition_status! requires an explicit actor' do
    application = create(:application, :in_progress, user: @constituent)

    error = assert_raises(ArgumentError) do
      application.transition_status!(:approved, actor: nil)
    end

    assert_equal 'actor is required', error.message
  end

  test 'application lifecycle wrappers require an explicit user' do
    application = create(:application, :in_progress, user: @constituent)

    assert_raises(ArgumentError) { application.approve! }
    assert_raises(ArgumentError) { application.reject! }
    assert_raises(ArgumentError) { application.request_documents! }
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

  private

  def with_after_commit_callbacks
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    setup_paper_application_context
    yield
  ensure
    clear_enqueued_jobs
    clear_performed_jobs
    Current.reset
    DatabaseCleaner.strategy = :transaction
  end
end
