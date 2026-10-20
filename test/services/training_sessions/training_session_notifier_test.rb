# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class TrainingSessionNotifierTest < ActiveSupport::TestCase
    test 'defers an explicit intent until the surrounding transaction commits' do
      session = create(:training_session)
      NotificationService.expects(:create_and_deliver!).never
      ActiveRecord::Base.transaction(requires_new: true) do
        outcome = TrainingSessionNotifier.new(session, actor: session.trainer, action: 'training_scheduled').deliver_after_commit
        assert_equal :deferred, outcome.status
        assert_nil outcome.notification_id
        assert_not outcome.warning?
        raise ActiveRecord::Rollback
      end
    end

    test 'rejects arbitrary notification actions' do
      session = create(:training_session)
      assert_raises(ArgumentError) do
        TrainingSessionNotifier.new(session, actor: session.trainer, action: 'private_notes')
      end
    end
  end
end
