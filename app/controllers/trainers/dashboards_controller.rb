# frozen_string_literal: true

module Trainers
  class DashboardsController < Trainers::BaseController
    def show
      # Set current filter from params or default to nil
      @current_filter = params[:filter]
      @current_status = params[:status]

      # Load base training sessions first
      load_training_sessions

      # Apply filter if provided
      apply_filter if @current_filter.present?

      # Load display data (always needed)
      load_display_data
    end

    private

    def load_training_sessions
      # Load data
      @requested_sessions = training_sessions.where(status: :requested)
                                             .order(created_at: :desc)
      @scheduled_sessions = training_sessions.where(status: :scheduled)
      @completed_sessions = training_sessions.where(status: :completed)
      @followup_sessions = training_sessions.where(status: %i[no_show cancelled])

      # Get all scheduled training sessions for the upcoming section
      @upcoming_sessions = @scheduled_sessions.order(scheduled_for: :asc)
                                              .includes(application: :user)

      # Get count for any training sessions assigned to this user
      # For admins, always use their own trainer_id for this count to ensure consistency
      @my_training_requests_count = TrainingSession.where(trainer_id: current_user.id)
                                                   .assigned_or_scheduled
                                                   .count
    end

    def apply_filter
      case @current_filter
      when 'requested'
        @filtered_sessions = @requested_sessions.order(created_at: :desc)
        @section_title = 'Requested Training Sessions'
      when 'scheduled'
        @filtered_sessions = @scheduled_sessions.order(scheduled_for: :asc)
        @section_title = 'Scheduled Training Sessions'
      when 'completed'
        @filtered_sessions = @completed_sessions.order(completed_at: :desc)
        @section_title = 'Completed Training Sessions'
      when 'needs_followup'
        @filtered_sessions = @followup_sessions.order(updated_at: :desc)
        @section_title = 'Training Sessions Needing Follow-up'
      end

      # Always include applications for display
      @filtered_sessions = @filtered_sessions.includes(application: :user) if @filtered_sessions.present?
    end

    def load_display_data
      # Always initialize these to empty arrays to prevent nil errors
      @requested_sessions_display = []
      @upcoming_sessions_display = []
      @recent_completed_sessions = []
      @recent_followup_sessions = [] # Added for default display

      # If we're filtering, don't load all the display data
      return if @current_filter.present?

      # Data for dashboard tables - limit to 10 items for each section
      @requested_sessions_display = @requested_sessions.includes(application: :user).limit(10)
      @upcoming_sessions_display = @upcoming_sessions.limit(10)
      @recent_completed_sessions = @completed_sessions.includes(application: :user).order(completed_at: :desc).limit(5)
      @recent_followup_sessions = @followup_sessions.includes(application: :user).order(updated_at: :desc).limit(5) # Added for default display
    end

    def training_sessions
      @training_sessions ||= if current_user.admin?
                               # Show all training sessions for admins
                               TrainingSession.includes(application: :user)
                             else
                               # Show only the trainer's own sessions for trainers
                               TrainingSession.where(trainer_id: current_user.id)
                                              .includes(application: :user)
                             end
    end
  end
end
