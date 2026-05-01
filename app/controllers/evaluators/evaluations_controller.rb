# frozen_string_literal: true

module Evaluators
  class EvaluationsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_evaluator!
    before_action :set_evaluation,
                  except: %i[index new create pending completed requested scheduled needs_followup filter]
    before_action :authorize_evaluation_mutation!, only: %i[edit update schedule reschedule submit_report request_additional_info]

    def index
      # Redirect to dashboard for main entry point
      # If specific filters are applied, still show the filtered list
      if params[:status].present? || params[:scope].present? || params[:filter].present?
        @evaluations = if current_user.evaluator?
                         # For evaluators, show only their evaluations
                         current_user.evaluations.includes(:constituent).order(created_at: :desc)
                       else
                         # For admins, show all evaluations
                         Evaluation.includes(:constituent).order(created_at: :desc)
                       end
      else
        redirect_to evaluators_dashboard_path
      end
    end

    # New filter action to handle combined scope + status filtering
    def filter
      scope_param = params[:scope] || (current_user.admin? ? 'all' : 'mine')
      status_param = params[:status]

      # Apply filters
      @evaluations = filter_evaluations(scope_param, status_param)

      # Set current selections for UI state
      @current_scope = scope_param
      @current_status = status_param

      render :index
    end

    def requested
      @evaluations = if current_user.admin?
                       Evaluation.where(status: :requested)
                                 .includes(:constituent)
                                 .order(created_at: :desc)
                     else
                       current_user.evaluations.requested_sessions
                                   .includes(:constituent)
                                   .order(created_at: :desc)
                     end
      render :index
    end

    def scheduled
      @evaluations = if current_user.admin?
                       Evaluation.where(status: %i[scheduled confirmed])
                                 .includes(:constituent)
                                 .order(evaluation_date: :asc)
                     else
                       current_user.evaluations.active
                                   .includes(:constituent)
                                   .order(evaluation_date: :asc)
                     end
      render :index
    end

    def pending
      @evaluations = current_user.evaluations.pending
                                 .includes(:constituent)
                                 .order(created_at: :desc)
      render :index
    end

    def completed
      @evaluations = current_user.evaluations.completed_sessions
                                 .includes(:constituent)
                                 .order(evaluation_date: :desc)
      render :index
    end

    def needs_followup
      @evaluations = if current_user.admin?
                       Evaluation.where(status: %i[no_show cancelled])
                                 .includes(:constituent)
                                 .order(updated_at: :desc)
                     else
                       current_user.evaluations.needing_followup
                                   .includes(:constituent)
                                   .order(updated_at: :desc)
                     end
      render :index
    end

    def show
      # @evaluation is set by set_evaluation
      prepare_show_context
    end

    def new
      @evaluation = current_user.evaluations.build
    end

    def edit
      # @evaluation is set by set_evaluation
    end

    def create
      @evaluation = current_user.evaluations.build(evaluation_params)
      @evaluation.status ||= :pending
      @evaluation.evaluation_type ||= :initial
      @evaluation.attendees ||= []
      @evaluation.products_tried ||= []
      @evaluation.recommended_product_ids ||= []

      if @evaluation.save
        redirect_to evaluators_evaluation_path(@evaluation),
                    notice: 'Evaluation created successfully.'
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      if completing_evaluation?
        result = ::Evaluations::SubmissionService.new(@evaluation, params, actor: current_user).call

        if result.success?
          redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
        else
          prepare_show_context
          flash.now[:alert] = "Failed to submit evaluation: #{result.message}"
          render :show, status: :unprocessable_content
        end
        return
      end

      if @evaluation.update(evaluation_params)
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation updated successfully.'
      else
        # If updating from the show page forms, we want to re-render show with errors
        # rather than the generic edit page
        prepare_show_context
        render :show, status: :unprocessable_content
      end
    end

    def schedule
      result = ::Evaluations::ScheduleService.new(@evaluation, current_user, schedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation scheduled successfully.'
      else
        prepare_show_context
        flash.now[:alert] = "Failed to schedule evaluation: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def reschedule
      result = ::Evaluations::RescheduleService.new(@evaluation, current_user, reschedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation rescheduled successfully.'
      else
        prepare_show_context
        flash.now[:alert] = "Failed to reschedule evaluation: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def submit_report
      result = ::Evaluations::SubmissionService.new(@evaluation, params, actor: current_user).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        flash.now[:alert] = "Failed to submit evaluation: #{result.message}"
        render :edit, status: :unprocessable_content
      end
    end

    def request_additional_info
      @evaluation.request_additional_info!
      redirect_to evaluators_evaluation_path(@evaluation), notice: 'Requested additional information.'
    end

    private

    def prepare_show_context
      @can_manage_evaluation = assigned_evaluator?
      @activity_logs = ::Evaluations::AuditLogBuilder.new(@evaluation).build
      @available_products = Product.order(:name)
    end

    def completing_evaluation?
      params.dig(:evaluation, :status).to_s == 'completed' && !@evaluation.status_completed?
    end

    def set_evaluation
      # If the current user is an admin, find the evaluation directly by ID
      @evaluation = if current_user.admin?
                      Evaluation.find(params[:id])
                    else
                      # For evaluators, find only their own evaluations
                      current_user.evaluations.find(params[:id])
                    end
    rescue ActiveRecord::RecordNotFound
      redirect_to evaluators_evaluations_path, alert: 'Evaluation not found.'
    end

    def evaluation_params
      params.expect(
        evaluation: [:constituent_id,
                     :application_id,
                     :evaluation_date,
                     :evaluation_type,
                     :status,
                     :notes,
                     :post_completion_notes,
                     :location,
                     :reschedule_reason,
                     :attendees_field,
                     { attendees: %i[name relationship],
                       products_tried: %i[product_id reaction],
                       products_tried_field: [],
                       recommended_product_ids: [] }]
      )
    end

    def schedule_params
      if params[:evaluation].present?
        params.expect(evaluation: %i[evaluation_date location notes])
      else
        params.permit(:evaluation_date, :location, :notes)
      end
    end

    def reschedule_params
      if params[:evaluation].present?
        params.expect(evaluation: %i[evaluation_date location reschedule_reason])
      else
        params.permit(:evaluation_date, :location, :reschedule_reason)
      end
    end

    def require_evaluator!
      return if current_user&.evaluator? || current_user&.admin?

      redirect_to root_path, alert: 'Not authorized'
    end

    def authorize_evaluation_mutation!
      return if assigned_evaluator?

      redirect_target = current_user&.admin? ? evaluators_evaluation_path(@evaluation) : evaluators_evaluations_path
      redirect_to redirect_target, alert: 'Only the assigned evaluator can update this evaluation.'
    end

    def filter_evaluations(_scope, status)
      # Base query - either all sessions or just mine
      base_query = if current_user.admin?
                     # For administrators, they don't have an 'evaluations' association
                     # So regardless of scope, we start with all evaluations
                     Evaluation.all
                   else
                     # For regular evaluators, use their association
                     current_user.evaluations
                   end

      # Apply status filter if provided
      filtered_query = if status.present?
                         base_query.where(status: status)
                       else
                         base_query
                       end

      # Apply appropriate order based on status
      ordered_query =
        case status
        when 'completed'
          filtered_query.order(evaluation_date: :desc)
        when 'scheduled', 'confirmed'
          filtered_query.order(evaluation_date: :asc)
        when 'requested'
          filtered_query.order(created_at: :desc)
        when 'no_show', 'cancelled', nil, ''
          # Fall through to default
          nil
        end

      ordered_query ||= filtered_query.order(updated_at: :desc)

      # Include only constituent since that's all we use in the view
      ordered_query.includes(:constituent)
    end

    def assigned_evaluator?
      @evaluation&.evaluator_id == current_user&.id
    end
  end
end
