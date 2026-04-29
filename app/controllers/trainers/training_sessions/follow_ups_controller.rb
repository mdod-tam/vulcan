# frozen_string_literal: true

module Trainers
  module TrainingSessions
    class FollowUpsController < Trainers::BaseController
      before_action :set_training_session
      before_action :authorize_training_session_mutation!

      def create
        result = ::TrainingSessions::ScheduleFollowUpService.new(@training_session, current_user, follow_up_params).call

        if result.success?
          redirect_to trainers_training_session_path(result.data[:training_session]), notice: result.message
        else
          redirect_to trainers_training_session_path(@training_session),
                      alert: t('trainers.training_sessions.flash.follow_up_failed', message: result.message)
        end
      end

      private

      def set_training_session
        @training_session = TrainingSession.find(params[:training_session_id])
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.error { "ERROR: TrainingSession not found with ID #{params[:training_session_id]}. #{e.message}" }
        raise e
      end

      def authorize_training_session_mutation!
        # Admins stay read-only here; they resolve trainer coverage from the admin application view.
        return if @training_session.trainer_id == current_user&.id

        redirect_target = current_user&.admin? ? trainers_training_session_path(@training_session) : trainers_dashboard_path
        redirect_to redirect_target, alert: t('trainers.training_sessions.flash.assigned_trainer_only')
      end

      def follow_up_params
        params.permit(:scheduled_for, :reschedule_reason, :location)
      end
    end
  end
end
