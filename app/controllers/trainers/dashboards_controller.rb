# frozen_string_literal: true

module Trainers
  class DashboardsController < Trainers::BaseController
    TRAINING_ACTIVITY_ACTIONS = %w[
      training_scheduled
      training_completed
      training_cancelled
      training_rescheduled
      training_followup_scheduled
      training_no_show
      training_missed
      training_status_changed
    ].freeze

    def show
      # Load base training sessions first
      load_training_sessions

      # Load display data (always needed)
      load_display_data
      load_recent_activity
    end

    private

    def load_training_sessions
      now = Time.current
      @requested_sessions = training_sessions.where(status: :requested)
                                             .includes(application: :user)
                                             .order(created_at: :desc, id: :desc)
      @scheduled_sessions = training_sessions.where(status: %i[scheduled confirmed])
      @scheduled_sessions_count = @scheduled_sessions.count
      @overdue_sessions = @scheduled_sessions.where(scheduled_for: ..now).includes(application: :user).order(:scheduled_for, :id)
      @overdue_sessions_count = @overdue_sessions.count
      @completed_sessions = training_sessions.where(status: :completed)
      @followup_sessions = ordered_followup_sessions
      load_admin_training_sessions
      @pending_training_requests = if current_user.admin?
                                     Application.with_pending_training_request
                                                .includes(:user)
                                                .order(training_requested_at: :asc, id: :asc)
                                   else
                                     Application.with_pending_training_request.where(assigned_trainer_id: current_user.id)
                                                .includes(:user).order(:training_requested_at, :id)
                                   end
      @needs_scheduling_count = @requested_sessions.count + @pending_training_requests.count
      @pending_request_sessions = TrainingSession.latest_per_application_records
                                                 .where(application: @pending_training_requests)
                                                 .index_by(&:application_id)
      @followup_sessions_count = @followup_sessions.count
      @my_scheduled_sessions_count = current_user.admin? ? @my_scheduled_sessions.count : 0

      # Get all scheduled training sessions for the upcoming section
      @upcoming_sessions = @scheduled_sessions.where('scheduled_for > ?', now).order(:scheduled_for, :id)
                                              .includes(application: :user)
      @my_upcoming_sessions = @my_scheduled_sessions.where('scheduled_for > ?', now)
    end

    def load_admin_training_sessions
      @my_scheduled_sessions = TrainingSession.none
      return unless current_user.admin?

      @my_scheduled_sessions = TrainingSession.where(trainer_id: current_user.id, status: %i[scheduled confirmed])
                                              .includes(application: :user)
                                              .order(scheduled_for: :asc)
    end

    def load_display_data
      @overdue_sessions_display = @overdue_sessions.limit(10)
      @requested_sessions_display = @requested_sessions.limit(10)
      @upcoming_sessions_display = @upcoming_sessions.limit(10)
      @my_scheduled_sessions_display = @my_upcoming_sessions.limit(10)
      @recent_completed_sessions = @completed_sessions
                                   .includes(application: :user)
                                   .order(completed_at: :desc)
                                   .limit(5)
      @recent_followup_sessions = @followup_sessions.limit(5)
    end

    def ordered_followup_sessions
      scope = TrainingSession.ordered_followup_per_application
      current_user.admin? ? scope : scope.joins(:application).where(trainer_id: current_user.id, applications: { assigned_trainer_id: current_user.id })
    end

    def load_recent_activity
      @activity_logs = if current_user.admin?
                         admin_recent_activity
                       else
                         trainer_recent_activity
                       end
      preload_auditable_associations(@activity_logs)
    end

    def admin_recent_activity
      Event.includes(:user, :auditable)
           .where(action: TRAINING_ACTIVITY_ACTIONS)
           .where("auditable_type = 'TrainingSession' OR metadata ? 'training_session_id'")
           .order(created_at: :desc)
           .limit(10)
           .to_a
    end

    def trainer_recent_activity
      training_session_ids = training_sessions.unscope(:includes).pluck(:id)
      return [] if training_session_ids.blank?

      Event.includes(:user, :auditable)
           .where(action: TRAINING_ACTIVITY_ACTIONS)
           .where(
             "(auditable_type = 'TrainingSession' AND auditable_id IN (:ids)) OR metadata->>'training_session_id' IN (:id_strings)",
             ids: training_session_ids,
             id_strings: training_session_ids.map(&:to_s)
           )
           .order(created_at: :desc)
           .limit(10)
           .to_a
    end

    def preload_auditable_associations(events)
      by_type = events.filter_map(&:auditable).group_by(&:class)
      ActiveRecord::Associations::Preloader.new(records: by_type[Application], associations: [:user]).call if by_type[Application]
      ActiveRecord::Associations::Preloader.new(records: by_type[Evaluation], associations: [:constituent]).call if by_type[Evaluation]
      ActiveRecord::Associations::Preloader.new(records: by_type[TrainingSession], associations: [:constituent]).call if by_type[TrainingSession]
    end

    def training_sessions
      @training_sessions ||= if current_user.admin?
                               # Show all training sessions for admins
                               TrainingSession.includes(application: :user)
                             else
                               # Show only the trainer's own sessions for trainers
                               TrainingSession.where(trainer_id: current_user.id).joins(:application)
                                              .where('applications.assigned_trainer_id = :trainer OR training_sessions.status = :completed',
                                                     trainer: current_user.id, completed: TrainingSession.statuses.fetch('completed'))
                                              .includes(application: :user)
                             end
    end
  end
end
