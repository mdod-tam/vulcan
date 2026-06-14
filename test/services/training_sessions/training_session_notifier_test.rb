# frozen_string_literal: true

require 'test_helper'

module TrainingSessions
  class TrainingSessionNotifierTest < ActiveSupport::TestCase
    setup do
      @trainer = create(:trainer)
      @application = create(:application, :approved, user: create(:constituent), application_date: 1.year.ago)
    end

    test 'delivers scheduled notifications to constituents' do
      training_session = create(:training_session, :requested, application: @application, trainer: @trainer)
      training_session.update!(status: :scheduled, scheduled_for: 1.week.from_now)

      NotificationService.expects(:create_and_deliver!).once.with do |params|
        params[:type] == 'training_scheduled' &&
          params[:recipient] == @application.user &&
          params[:actor] == @trainer &&
          params[:notifiable] == training_session &&
          params[:channel] == :email
      end

      TrainingSessionNotifier.new(training_session).deliver_all
    end

    test 'does not deliver completed notifications to constituents' do
      training_session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
      training_session.update!(status: :completed, notes: 'Training completed')

      NotificationService.expects(:create_and_deliver!).never

      TrainingSessionNotifier.new(training_session).deliver_all
    end
  end
end
