# frozen_string_literal: true

require 'test_helper'

class IssueInitialVoucherJobTest < ActiveJob::TestCase
  setup do
    setup_paper_application_context
    FeatureFlag.enable!(:vouchers_enabled)
  end

  teardown do
    Current.reset
    FeatureFlag.disable!(:vouchers_enabled)
  end

  test 'delegates initial voucher assignment to the application' do
    application = create(:application)
    actor = create(:admin)

    Application.expects(:find_by).with(id: application.id).returns(application)
    User.expects(:find_by).with(id: actor.id).returns(actor)
    application.expects(:maybe_assign_initial_voucher!).with(
      actor: actor,
      assignment_method: :automatic
    ).once

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

  test 'retries assignment failures' do
    application = create(:application)
    actor = create(:admin)

    Application.stubs(:find_by).with(id: application.id).returns(application)
    User.stubs(:find_by).with(id: actor.id).returns(actor)
    application.stubs(:maybe_assign_initial_voucher!).raises(StandardError, 'voucher write failed')

    assert_enqueued_jobs 1, only: IssueInitialVoucherJob do
      IssueInitialVoucherJob.perform_now(application.id, actor.id)
    end
  end
end
