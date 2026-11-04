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
