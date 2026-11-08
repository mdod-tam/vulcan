# frozen_string_literal: true

require 'test_helper'

module Vouchers
  class IssuanceServiceTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      DatabaseCleaner.clean
      Current.reset
      @actor = create(:admin)
      FeatureFlag.enable!(:vouchers_enabled)
      @application = create(:application, :completed, :voucher_fulfillment)
      clear_enqueued_jobs
    end

    teardown do
      clear_enqueued_jobs
      Current.reset
      DatabaseCleaner.clean_with(:truncation)
    end

    test 'an audit failure rolls back issuance inside an enclosing transaction' do
      AuditEventService.stubs(:log).raises(RuntimeError, 'audit unavailable')
      assert_no_difference ['Voucher.count', 'Event.count'] do
        Application.transaction do
          @application.update!(last_activity_at: 1.hour.ago)
          result = IssuanceService.new(@application, actor: @actor).call
          assert_predicate result, :failure?
          assert_equal 'Voucher could not be issued', result.message
          assert_equal 1, Application.connection.select_value('SELECT 1')
        end
      end
      assert @application.reload.last_activity_at
      assert_no_enqueued_jobs
    end

    test 'an enqueue failure before commit leaves no voucher or assignment event' do
      delivery = mock
      delivery.expects(:deliver_later).raises(RuntimeError, 'queue unavailable')
      VoucherNotificationsMailer.expects(:with).returns(stub(voucher_assigned: delivery))
      assert_no_difference ['Voucher.count', 'Event.count'] do
        result = IssuanceService.new(@application, actor: @actor).call
        assert_predicate result, :failure?
      end
    end

    test 'the automatic job retries a confirmed rollback without leaving issuance side effects' do
      AuditEventService.stubs(:log).raises(RuntimeError, 'audit unavailable')

      assert_no_difference ['Voucher.count', 'Event.count', 'Notification.count'] do
        assert_enqueued_jobs 1, only: IssueInitialVoucherJob do
          IssueInitialVoucherJob.perform_now(@application.id, @actor.id)
        end
      end
    end

    test 'failure before creating the voucher is a confirmed rollback and can be retried without side effects' do
      sentinel = 'private eligibility failure person@example.test'
      Application.any_instance.stubs(:can_create_voucher?).raises(RuntimeError, sentinel)

      assert_no_difference ['Voucher.count', 'Event.count', 'Notification.count'] do
        error = assert_raises(IssuanceService::RolledBackFailure) do
          IssuanceService.new(@application, actor: @actor, raise_on_failure: true).call
        end
        assert_not_includes error.message, sentinel
        assert_nil error.cause

        assert_enqueued_jobs 1, only: IssueInitialVoucherJob do
          IssueInitialVoucherJob.perform_now(@application.id, @actor.id)
        end
      end
    end

    test 'completion failure reports the committed voucher and warns against duplicate issuance' do
      with_completion_failure do
        result = IssuanceService.new(@application, actor: @actor).call
        assert_predicate result, :success?
        assert result.data[:warning]
        assert_match 'Check delivery before retrying', result.message
        voucher = Voucher.find_by!(application: @application)
        assert_equal voucher.id, result.data[:voucher].id
        assert Event.exists?(auditable: voucher, action: 'voucher_assigned')
      end
    end

    test 'unavailable completion readback preserves an unknown outcome' do
      with_completion_failure do
        original = Voucher.method(:exists?)
        readback = lambda do |condition|
          raise ActiveRecord::ConnectionNotEstablished if condition.is_a?(Integer)

          original.call(condition)
        end
        result = Voucher.stub(:exists?, readback) { IssuanceService.new(@application, actor: @actor, raise_on_failure: true).call }
        assert_predicate result, :failure?
        assert_equal :unknown, result.data[:commit_state]
        assert_match 'Check the application before retrying', result.message
        assert_nil result.data[:voucher]
        assert_equal 1, Voucher.where(application: @application).count
        assert_equal 1, Event.where(action: 'voucher_assigned', auditable_type: 'Voucher').count
      end
    end

    test 'the automatic job records committed follow-up attention and does not issue a second voucher' do
      with_completion_failure do
        assert_no_enqueued_jobs only: IssueInitialVoucherJob do
          assert_difference 'Voucher.count', 1 do
            IssueInitialVoucherJob.perform_now(@application.id, @actor.id)
          end
        end
      end

      voucher = Voucher.find_by!(application: @application)
      event = Event.find_by!(auditable: @application, action: 'initial_voucher_issuance_attention')
      notification = Notification.find_by!(notifiable: @application, action: 'initial_voucher_issuance_attention')
      assert_equal 'committed', event.metadata['commit_state']
      assert_equal voucher.id, event.metadata['voucher_id']
      assert_equal @actor, notification.recipient
      assert_equal @actor, notification.actor
      assert_nil notification.delivery_status
      assert_not notification.email_delivery_attempts.exists?
      assert Event.exists?(auditable: voucher, action: 'voucher_assigned')

      assert_no_difference ['Voucher.count', 'Event.count', 'Notification.count'] do
        IssueInitialVoucherJob.perform_now(@application.id, @actor.id)
      end
    end

    test 'the automatic job records unknown issuance without scheduling another attempt' do
      with_completion_failure do
        original = Voucher.method(:exists?)
        readback = lambda do |condition|
          raise ActiveRecord::ConnectionNotEstablished if condition.is_a?(Integer)

          original.call(condition)
        end

        assert_no_enqueued_jobs only: IssueInitialVoucherJob do
          Voucher.stub(:exists?, readback) { IssueInitialVoucherJob.perform_now(@application.id, @actor.id) }
        end
      end

      assert_equal 1, Voucher.where(application: @application).count
      assert_equal 1, Event.where(action: 'voucher_assigned', auditable_type: 'Voucher').count
      event = Event.find_by!(auditable: @application, action: 'initial_voucher_issuance_attention')
      assert_equal 'unknown', event.metadata['commit_state']
      assert_nil event.metadata['voucher_id']
      assert Notification.exists?(notifiable: @application, recipient: @actor, action: 'initial_voucher_issuance_attention')
    end

    test 'attention recording failure retains the committed voucher and fails with safe manual recovery context' do
      sentinel = 'private exception person@example.test secret=do-not-copy'
      NotificationService.expects(:create_and_deliver!).raises(RuntimeError, sentinel)
      job = IssueInitialVoucherJob.new(@application.id, @actor.id)
      error = nil

      with_completion_failure do
        assert_no_enqueued_jobs only: IssueInitialVoucherJob do
          error = assert_raises(IssueInitialVoucherJob::AttentionRecordingFailed) do
            job.perform_now
          end
        end
      end

      voucher = Voucher.find_by!(application: @application)
      assert Event.exists?(auditable: voucher, action: 'voucher_assigned')
      assert_not Event.exists?(auditable: @application, action: 'initial_voucher_issuance_attention')
      assert_not Notification.exists?(notifiable: @application, action: 'initial_voucher_issuance_attention')
      assert_includes error.message, "application_id=#{@application.id}"
      assert_includes error.message, "voucher_id=#{voucher.id}"
      assert_includes error.message, "job_id=#{job.job_id}"
      assert_includes error.message, 'commit_state=committed'
      assert_includes error.message, 'Check voucher and delivery status'
      assert_not_includes error.message, sentinel
      assert_nil error.cause
    end

    private

    def with_completion_failure
      application_id = @application.id
      callback = -> { raise 'completion failed' if self.application_id == application_id }
      Voucher.set_callback(:commit, :after, callback)
      yield
    ensure
      Voucher.skip_callback(:commit, :after, callback)
    end
  end
end
