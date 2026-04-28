# frozen_string_literal: true

module Trainers
  # Controller for managing training sessions for trainers.
  # Handles listing, filtering, showing, and updating the status of training sessions.
  class TrainingSessionsController < Trainers::BaseController
    before_action :set_training_session, only: %i[show update_status complete schedule reschedule cancel] # Removed :edit
    before_action :authorize_training_session_mutation!, only: %i[update_status complete schedule reschedule cancel]

    def index
      if params[:status].present? || params[:scope].present? || params[:filter].present?
        filter # Delegate to the filter action if parameters are present
      else
        redirect_to trainers_dashboard_path
      end
    end

    # New action for handling scope + status filtering
    def filter
      scope_param = params[:scope] || (current_user.admin? ? 'all' : 'mine')

      # If not admin, force scope to 'mine' regardless of params
      scope_param = 'mine' unless current_user.admin?

      status_param = params[:status]

      # Apply filters
      @training_sessions = filter_sessions(scope_param, status_param)

      # Set current selections for UI state
      @current_scope = scope_param
      @current_status = status_param
      @trainer_filter = User.find_by(id: params[:trainer_id]) if current_user.admin? && params[:trainer_id].present?

      @pagy, @training_sessions = pagy(@training_sessions, items: 20)
      render :index
    end

    def requested
      scope = if current_user.admin?
                TrainingSession.where(status: :requested)
                               .includes(application: :user)
                               .order(created_at: :desc)
              else
                TrainingSession.where(trainer_id: current_user.id, status: :requested)
                               .includes(application: :user)
                               .order(created_at: :desc)
              end

      @pagy, @training_sessions = pagy(scope, items: 20)
      render :index
    end

    def scheduled
      scope = if current_user.admin?
                TrainingSession.where(status: :scheduled)
                               .includes(application: :user)
                               .order(scheduled_for: :asc)
              else
                TrainingSession.where(trainer_id: current_user.id, status: :scheduled)
                               .includes(application: :user)
                               .order(scheduled_for: :asc)
              end

      @pagy, @training_sessions = pagy(scope, items: 20)
      render :index
    end

    def completed
      scope = if current_user.admin?
                TrainingSession.where(status: :completed)
                               .includes(application: :user)
                               .order(completed_at: :desc)
              else
                TrainingSession.where(trainer_id: current_user.id, status: :completed)
                               .includes(application: :user)
                               .order(completed_at: :desc)
              end

      @pagy, @training_sessions = pagy(scope, items: 20)
      render :index
    end

    def needs_followup
      scope = if current_user.admin?
                TrainingSession.where(status: %i[no_show cancelled])
                               .includes(application: :user)
                               .order(updated_at: :desc)
              else
                TrainingSession.where(trainer_id: current_user.id, status: %i[no_show cancelled])
                               .includes(application: :user)
                               .order(updated_at: :desc)
              end

      @pagy, @training_sessions = pagy(scope, items: 20)
      render :index
    end

    def show
      prepare_show_context
    end

    def update_status
      @application = @training_session.application
      @constituent = @application&.user

      result = TrainingSessions::UpdateStatusService.new(@training_session, current_user, params).call

      if result.success?
        redirect_to trainers_training_session_path(@training_session),
                    notice: result.message
      else
        @training_session.reload # Reset invalid changes so the view renders correctly
        prepare_show_context
        flash.now[:alert] = "Failed to update training session status: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def complete
      @application = @training_session.application
      @constituent = @application&.user

      result = TrainingSessions::CompleteService.new(@training_session, current_user, complete_params).call

      if result.success?
        redirect_to trainers_training_session_path(@training_session), notice: result.message
      else
        @training_session.reload # Reset invalid changes so the view renders correctly
        prepare_show_context
        flash.now[:alert] = "Failed to complete training session: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def schedule
      @application = @training_session.application
      @constituent = @application&.user

      result = TrainingSessions::ScheduleService.new(@training_session, current_user, schedule_params).call

      if result.success?
        redirect_to trainers_training_session_path(@training_session),
                    notice: result.message
      else
        @training_session.reload # Reset invalid changes so the view renders correctly
        prepare_show_context
        flash.now[:alert] = "Failed to schedule training session: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def reschedule
      @application = @training_session.application
      @constituent = @application&.user

      result = TrainingSessions::RescheduleService.new(@training_session, current_user, reschedule_params).call

      if result.success?
        redirect_to trainers_training_session_path(@training_session),
                    notice: result.message
      else
        @training_session.reload # Reset invalid changes so the view renders correctly
        prepare_show_context
        flash.now[:alert] = "Failed to reschedule training session: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    # New action to handle training session cancellation
    def cancel
      @application = @training_session.application
      @constituent = @application&.user

      result = TrainingSessions::CancelService.new(@training_session, current_user, cancel_params).call

      if result.success?
        redirect_to trainers_training_session_path(@training_session), notice: result.message
      else
        @training_session.reload # Reset invalid changes so the view renders correctly
        prepare_show_context
        flash.now[:alert] = "Failed to cancel training session: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    private

    def prepare_show_context
      @application = @training_session.application
      @constituent = @application.user
      @max_training_sessions = @application.max_training_sessions
      @completed_training_sessions_count = @application.completed_training_sessions_count
      @session_number = calculate_session_number
      @previous_training_sessions = @training_session.previous_completed_sessions
      @constituent_cancelled_sessions_count = count_constituent_cancelled_sessions
      @activity_logs = TrainingSessions::AuditLogBuilder.new(@training_session).build
    end

    def filter_sessions(scope, status)
      query = if scope == 'all' && current_user.admin?
                TrainingSession.all
              else
                TrainingSession.where(trainer_id: current_user.id)
              end.then do |q|
                status.present? ? q.where(status: status) : q
              end
      query = query.where(trainer_id: params[:trainer_id]) if current_user.admin? && params[:trainer_id].present?

      ordering = {
        'completed' => { completed_at: :desc },
        'scheduled' => { scheduled_for: :asc },
        'requested' => { created_at: :desc }
      }[status] || { updated_at: :desc }

      query.order(ordering).includes(application: :user)
    end

    def set_training_session
      begin
        @training_session = TrainingSession.find(params[:id])
      rescue ActiveRecord::RecordNotFound => e
        # Log the error for debugging purposes
        Rails.logger.error { "ERROR: TrainingSession not found with ID #{params[:id]}. #{e.message}" }
        # Re-raise to trigger standard Rails 404 handling
        raise e
      end

      # Authorization check: Allow admins or the assigned trainer
      return if current_user&.admin? || assigned_trainer?

      # If not authorized, redirect with an alert
      redirect_to trainers_dashboard_path, alert: "You don't have access to this training session."
    ensure
      @can_manage_training_session = assigned_trainer?
    end

    def authorize_training_session_mutation!
      return if assigned_trainer?

      redirect_target = current_user&.admin? ? trainers_training_session_path(@training_session) : trainers_dashboard_path
      redirect_to redirect_target, alert: 'Only the assigned trainer can update this training session.'
    end

    def training_session_params
      params.expect(
        training_session: %i[
          status notes scheduled_for reschedule_reason cancellation_reason
          product_trained_on_id location
        ]
      )
    end

    def schedule_params
      params.permit(:scheduled_for, :notes, :location)
    end

    def reschedule_params
      params.permit(:scheduled_for, :reschedule_reason, :location)
    end

    def complete_params
      params.permit(:notes, :product_trained_on_id)
    end

    def cancel_params
      params.permit(:cancellation_reason)
    end

    def create_status_change_event(old_status)
      AuditEventService.log(
        actor: current_user,
        action: 'training_status_changed',
        auditable: @training_session,
        metadata: {
          application_id: @training_session.application_id,
          training_session_id: @training_session.id,
          old_status: old_status,
          new_status: @training_session.status,
          timestamp: Time.current.iso8601
        }
      )
    end

    def calculate_session_number
      if @training_session.status_completed?
        completed_ids = @application.training_sessions.completed_sessions.order(:completed_at, :created_at).pluck(:id)
        return completed_ids.index(@training_session.id).to_i + 1
      end

      return @application.completed_training_sessions_count + 1 if @training_session.status_requested? ||
                                                                   @training_session.status_scheduled? ||
                                                                   @training_session.status_confirmed?

      nil
    end

    def count_constituent_cancelled_sessions
      constituent_training_session_ids = @constituent.applications.joins(:training_sessions).pluck('training_sessions.id')
      cancelled_sessions = TrainingSession.where(id: constituent_training_session_ids, status: :cancelled)
      no_show_count = TrainingSession.where(id: constituent_training_session_ids, status: :no_show).count

      @constituent_session_outcome_counts =
        if TrainingSession.cancellation_initiator_column?
          {
            constituent_cancellations: cancelled_sessions.where(cancellation_initiator: :constituent).count,
            no_shows: no_show_count,
            trainer_or_program_cancellations: cancelled_sessions.where.not(cancellation_initiator: :constituent).count
          }
        else
          {
            # Before the new column exists locally, avoid blaming constituents for historical cancellations
            # that cannot yet be attributed reliably.
            constituent_cancellations: 0,
            no_shows: no_show_count,
            trainer_or_program_cancellations: cancelled_sessions.count
          }
        end

      @constituent_session_outcome_counts[:constituent_cancellations] + @constituent_session_outcome_counts[:no_shows]
    end

    def assigned_trainer?
      @training_session&.trainer_id == current_user&.id
    end
  end
end
