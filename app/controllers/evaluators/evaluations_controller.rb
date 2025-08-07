# frozen_string_literal: true

module Evaluators
  class EvaluationsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_evaluator!
    before_action :set_evaluation,
                  except: %i[index new create pending completed requested scheduled needs_followup filter]

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
                       current_user.evaluations.requested_evaluations
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
      @evaluations = current_user.evaluations.completed_evaluations
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
      process_attendees_param
      process_products_tried_param

      if @evaluation.update(evaluation_params)
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation updated successfully.'
      else
        render :edit, status: :unprocessable_content
      end
    end

    def schedule
      @evaluation.evaluation_date = params[:evaluation_date]
      @evaluation.location = params[:location]
      @evaluation.notes = params[:notes]
      @evaluation.status = :scheduled

      if @evaluation.save
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation scheduled successfully.'
      else
        redirect_to evaluators_evaluation_path(@evaluation), alert: @evaluation.errors.full_messages.join(', ')
      end
    end

    def reschedule
      @evaluation.evaluation_date = params[:evaluation_date]
      @evaluation.location = params[:location] if params[:location].present?
      @evaluation.reschedule_reason = params[:reschedule_reason]
      @evaluation.status = :scheduled # Reset to scheduled status

      if @evaluation.save
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation rescheduled successfully.'
      else
        redirect_to evaluators_evaluation_path(@evaluation), alert: @evaluation.errors.full_messages.join(', ')
      end
    end

    def submit_report
      service = Evaluations::SubmissionService.new(@evaluation, params)

      if service.submit
        redirect_to evaluators_evaluation_path(@evaluation),
                    notice: 'Evaluation submitted successfully.'
      else
        render :edit, status: :unprocessable_content
      end
    end

    def request_additional_info
      @evaluation.request_additional_info!
      redirect_to evaluators_evaluation_path(@evaluation), notice: 'Requested additional information.'
    end

    private

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
                     :evaluation_date,
                     :evaluation_type,
                     :status,
                     :notes,
                     :location,
                     :needs,
                     :reschedule_reason,
                     { attendees: %i[name relationship],
                       products_tried: %i[product_id reaction],
                       recommended_product_ids: [] }]
      )
    end

    def require_evaluator!
      return if current_user&.evaluator? || current_user&.admin?

      redirect_to root_path, alert: 'Not authorized'
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

    def process_attendees_param
      return if params[:evaluation][:attendees_field].blank?

      attendees = params[:evaluation][:attendees_field].split(',').map do |attendee_str|
        name, relationship = attendee_str.strip.split('-').map(&:strip)
        { 'name' => name, 'relationship' => relationship }
      end
      params[:evaluation][:attendees] = attendees
    end

    def process_products_tried_param
      return if params[:evaluation][:products_tried_field].blank?

      products_tried = params[:evaluation][:products_tried_field].map do |product_id|
        { 'product_id' => product_id, 'reaction' => 'Recorded during evaluation' }
      end
      params[:evaluation][:products_tried] = products_tried
    end
  end
end
