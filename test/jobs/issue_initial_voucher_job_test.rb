# frozen_string_literal: true

require 'test_helper'

class IssueInitialVoucherJobTest < ActiveJob::TestCase
  setup do
    ensure_system_audit_actor!
    setup_paper_application_context
    FeatureFlag.enable!(:vouchers_enabled)
  end

  teardown do
    Current.reset
    FeatureFlag.disable!(:vouchers_enabled)
  end

  test 'delegates initial voucher assignment to the issuance service' do
    application = create(:application)
    actor = create(:admin)

    Application.expects(:find_by).with(id: application.id).returns(application)
    User.expects(:find_by).with(id: actor.id).returns(actor)
    service = mock('issuance service')
    service.expects(:call).once.returns(BaseService::Result.new(success: true))
    Vouchers::IssuanceService.expects(:new).with(
      application, actor: actor, assignment_method: :automatic, raise_on_failure: true
    ).returns(service)

    IssueInitialVoucherJob.perform_now(application.id, actor.id)
  end

  test 'no-ops when application is missing' do
    actor = create(:admin)

    assert_nothing_raised do
      IssueInitialVoucherJob.perform_now(-1, actor.id)
    end
  end

  test 'no-ops when actor is missing' do
    application = create(:application, :completed, :voucher_fulfillment)

    assert_nothing_raised do
      IssueInitialVoucherJob.perform_now(application.id, -1)
    end
  end

  test 'is idempotent when a voucher already exists' do
    application = create(:application, :completed, :voucher_fulfillment)
    actor = create(:admin)
    create(:voucher, application: application)

    assert_no_difference -> { Voucher.where(application: application).count } do
      IssueInitialVoucherJob.perform_now(application.id, actor.id)
    end
  end

  test 'retries only confirmed rollback failures' do
    application = create(:application)
    actor = create(:admin)

    Application.stubs(:find_by).with(id: application.id).returns(application)
    User.stubs(:find_by).with(id: actor.id).returns(actor)
    Vouchers::IssuanceService.any_instance.stubs(:call).raises(Vouchers::IssuanceService::RolledBackFailure, 'Voucher issuance rolled back')

    assert_enqueued_jobs 1, only: IssueInitialVoucherJob do
      IssueInitialVoucherJob.perform_now(application.id, actor.id)
    end
  end

  test 'an unclassified error fails without automatically repeating issuance' do
    application = create(:application)
    actor = create(:admin)
    Vouchers::IssuanceService.any_instance.stubs(:call).raises(StandardError, 'unclassified failure')

    assert_no_enqueued_jobs only: IssueInitialVoucherJob do
      assert_raises(StandardError) { IssueInitialVoucherJob.perform_now(application.id, actor.id) }
    end
  end

  test 'disabled and ineligible issuance remain intentional no-ops' do
    application = create(:application, :in_progress)
    actor = create(:admin)

    assert_no_difference ['Voucher.count', 'Notification.count', 'Event.count'] do
      FeatureFlag.disable!(:vouchers_enabled)
      IssueInitialVoucherJob.perform_now(application.id, actor.id)
      FeatureFlag.enable!(:vouchers_enabled)
      IssueInitialVoucherJob.perform_now(application.id, actor.id)
    end
  end

  test 'an internal attention notice for a non-admin actor goes to the configured system administrator' do
    application = create(:application)
    actor = application.user
    Vouchers::IssuanceService.any_instance.stubs(:call).returns(
      BaseService::Result.new(success: false, data: { commit_state: :unknown })
    )

    IssueInitialVoucherJob.perform_now(application.id, actor.id)

    notification = Notification.find_by!(notifiable: application, action: 'initial_voucher_issuance_attention')
    assert_equal PublicAuditActor.system_audit_actor, notification.recipient
    assert_equal actor, notification.actor
    assert_nil notification.delivery_status
    assert_not notification.email_delivery_attempts.exists?
    assert_equal actor, Event.find_by!(auditable: application, action: 'initial_voucher_issuance_attention').user
  end

  test 'missing staff attention recipient fails safely without exposing the notice to a constituent or retrying issuance' do
    application = create(:application)
    actor = application.user
    Vouchers::IssuanceService.any_instance.stubs(:call).returns(
      BaseService::Result.new(success: false, data: { commit_state: :unknown })
    )
    PublicAuditActor.expects(:system_audit_actor).returns(nil)

    assert_no_enqueued_jobs only: IssueInitialVoucherJob do
      assert_no_difference ['Event.count', 'Notification.count'] do
        error = assert_raises(IssueInitialVoucherJob::AttentionRecordingFailed) do
          IssueInitialVoucherJob.perform_now(application.id, actor.id)
        end
        assert_includes error.message, "application_id=#{application.id}"
        assert_includes error.message, 'commit_state=unknown'
        assert_includes error.message, 'Check voucher and delivery status'
        assert_nil error.cause
      end
    end
  end
end
