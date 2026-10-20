# frozen_string_literal: true

module Trainers
  module TrainingSessions
    class FollowUpsController < Trainers::TrainingSessionsController
      before_action :set_training_session, only: :create
      before_action :authorize_training_session_mutation!, only: :create

      def create
        run_training_command(:follow_up, ::TrainingSessions::ScheduleFollowUpService)
      end
    end
  end
end
