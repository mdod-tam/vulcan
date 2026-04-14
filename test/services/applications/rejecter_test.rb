# frozen_string_literal: true

require 'test_helper'

module Applications
  class RejecterTest < ActiveSupport::TestCase
    setup do
      @application = create(:application, :in_progress)
      @admin = create(:admin)
    end

    test 'call transitions status to rejected and logs audit event' do
      rejecter = Rejecter.new(@application, by: @admin)

      assert_difference -> { ApplicationStatusChange.count }, 1 do
        assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
          assert rejecter.call
        end
      end

      @application.reload
      assert @application.status_rejected?

      status_change = @application.status_changes.last
      assert_equal 'rejected', status_change.to_status
      assert_equal @admin, status_change.user
      assert_equal 'admin_rejection', status_change.metadata['trigger']

      audit_event = @application.events.where(action: 'application_status_changed').last
      assert_equal @admin, audit_event.user
      assert_equal 'admin_rejection', audit_event.metadata['trigger']
    end
  end
end
