# frozen_string_literal: true

module Evaluators
  class DashboardsController < ApplicationController
    EVALUATION_ACTIVITY_ACTIONS = %w[
      evaluation_scheduled
      evaluation_rescheduled
      evaluation_completed
      requested_additional_info
    ].freeze

    before_action :authenticate_user!
    before_action :require_evaluator!

    def show
      # Set current filter from params or default to nil
      @current_filter = params[:filter]
      @current_status = params[:status]

      # Load data based on user type
      if current_user.admin?
        load_admin_data
      else
        load_evaluator_data
      end

      # Apply filter status if provided
      apply_filter if @current_filter.present?

      # Load display data (always needed)
      load_display_data
      load_recent_activity
    end

    private

    def load_admin_data
      # For admins, show all evaluations
      @requested_evaluations = Evaluation.requested_sessions
      @scheduled_evaluations = Evaluation.active
      @completed_evaluations = Evaluation.completed_sessions
      @followup_evaluations = Evaluation.needing_followup
      @assigned_constituents = Constituent.where(evaluator_id: Evaluator.select(:id)).to_a.uniq(&:id)
    end

    def load_evaluator_data
      # For evaluators, show only their evaluations
      @requested_evaluations = current_user.evaluations.requested_sessions
      @scheduled_evaluations = current_user.evaluations.active
      @completed_evaluations = current_user.evaluations.completed_sessions
      @followup_evaluations = current_user.evaluations.needing_followup
      @assigned_constituents = current_user.assigned_constituents.to_a.uniq(&:id)
    end

    def apply_filter
      evaluations = evaluations_for_filter(@current_filter)
      @filtered_evaluations = order_evaluations(evaluations, @current_filter)
      @section_title = section_title_for_filter(@current_filter)
    end

    def evaluations_for_filter(filter_type)
      case filter_type
      when 'requested'
        (current_user.admin? ? Evaluation.requested_sessions : current_user.evaluations.requested_sessions)
          .includes(:constituent, :application)
      when 'scheduled'
        (current_user.admin? ? Evaluation.active : current_user.evaluations.active)
          .includes(:constituent, :application)
      when 'completed'
        (current_user.admin? ? Evaluation.completed_sessions : current_user.evaluations.completed_sessions)
          .includes(:constituent, :application)
      when 'needs_followup'
        (current_user.admin? ? Evaluation.needing_followup : current_user.evaluations.needing_followup)
          .includes(:constituent, :application)
      end
    end

    def order_evaluations(evaluations, filter_type)
      case filter_type
      when 'requested'
        evaluations.order(created_at: :desc)
      when 'scheduled'
        evaluations.order(evaluation_date: :asc)
      when 'completed'
        evaluations.order(evaluation_date: :desc)
      when 'needs_followup'
        evaluations.order(updated_at: :desc)
      end
    end

    def section_title_for_filter(filter_type)
      {
        'requested' => 'Requested Evaluations',
        'scheduled' => 'Scheduled Evaluations',
        'completed' => 'Completed Evaluations',
        'needs_followup' => 'Evaluations Needing Follow-up'
      }[filter_type]
    end

    def load_display_data
      # Always initialize these variables to empty arrays
      @requested_evaluations_display = []
      @upcoming_evaluations = []
      @recent_evaluations = []

      # If we're filtering, don't load all the display data
      return if @current_filter.present?

      # Data for dashboard tables - limit to 5 items for each section
      @requested_evaluations_display = @requested_evaluations.includes(:constituent).order(created_at: :desc).limit(5)
      @upcoming_evaluations = (current_user.admin? ? Evaluation.active : current_user.evaluations.active)
                              .includes(:constituent).order(evaluation_date: :asc).limit(5)
      @recent_evaluations = (current_user.admin? ? Evaluation.completed_sessions : current_user.evaluations.completed_sessions)
                            .includes(:constituent, :application).order(evaluation_date: :desc).limit(5)
    end

    def load_recent_activity
      @activity_logs = if current_user.admin?
                         admin_recent_activity
                       else
                         evaluator_recent_activity
                       end
      preload_auditable_associations(@activity_logs)
    end

    def admin_recent_activity
      evaluation_events_scope = Event.includes(:user, :auditable)
                                     .where(action: EVALUATION_ACTIVITY_ACTIONS)
                                     .where("auditable_type = 'Evaluation' OR metadata ? 'evaluation_id'")
      application_events_scope = Event.includes(:user, :auditable)
                                      .where(action: ::Evaluations::AuditLogBuilder::APPLICATION_LEVEL_ACTIONS,
                                             auditable_type: 'Application')

      recent_activity(
        evaluation_events_scope: evaluation_events_scope,
        application_events_scope: application_events_scope
      )
    end

    def evaluator_recent_activity
      evaluation_ids = current_user.evaluations.pluck(:id)
      application_ids = current_user.evaluations.distinct.pluck(:application_id)

      return [] if evaluation_ids.blank? && application_ids.blank?

      evaluation_events_scope = scoped_evaluation_events(evaluation_ids)
      application_events_scope = scoped_application_events(application_ids)

      recent_activity(
        evaluation_events_scope: evaluation_events_scope,
        application_events_scope: application_events_scope
      )
    end

    def scoped_evaluation_events(evaluation_ids)
      return Event.none if evaluation_ids.blank?

      Event.includes(:user, :auditable)
           .where(action: EVALUATION_ACTIVITY_ACTIONS)
           .where(
             "(auditable_type = 'Evaluation' AND auditable_id IN (:ids)) OR metadata->>'evaluation_id' IN (:id_strings)",
             ids: evaluation_ids,
             id_strings: evaluation_ids.map(&:to_s)
           )
    end

    def scoped_application_events(application_ids)
      return Event.none if application_ids.blank?

      Event.includes(:user, :auditable)
           .where(action: ::Evaluations::AuditLogBuilder::APPLICATION_LEVEL_ACTIONS,
                  auditable_type: 'Application',
                  auditable_id: application_ids)
    end

    def recent_activity(evaluation_events_scope:, application_events_scope:)
      (evaluation_events_scope.order(created_at: :desc).limit(10).to_a +
        application_events_scope.order(created_at: :desc).limit(10).to_a)
        .uniq(&:id)
        .sort_by(&:created_at)
        .reverse
        .first(10)
    end

    def preload_auditable_associations(events)
      by_type = events.filter_map(&:auditable).group_by(&:class)
      ActiveRecord::Associations::Preloader.new(records: by_type[Application], associations: [:user]).call if by_type[Application]
      ActiveRecord::Associations::Preloader.new(records: by_type[Evaluation], associations: [:constituent]).call if by_type[Evaluation]
      ActiveRecord::Associations::Preloader.new(records: by_type[TrainingSession], associations: [:constituent]).call if by_type[TrainingSession]
    end

    def require_evaluator!
      return if current_user&.evaluator? || current_user&.admin?

      redirect_to root_path, alert: 'Access denied'
    end
  end
end
