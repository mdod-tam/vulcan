# frozen_string_literal: true

module Evaluators
  class EvaluationsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_evaluator!
    before_action :set_evaluation,
                  except: %i[index new create pending completed requested scheduled needs_followup filter]
    before_action :authorize_evaluation_mutation!,
                  only: %i[edit update schedule reschedule submit_report cancel no_show request_additional_info]

    def index
      # Unfiltered visits enter through the dashboard.
      if params[:status].present? || params[:scope].present? || params[:filter].present?
        filter
      else
        redirect_to evaluators_dashboard_path
      end
    end

    def filter
      render_filtered_evaluations(params[:status])
    end

    def requested
      render_filtered_evaluations('requested')
    end

    def scheduled
      render_filtered_evaluations('scheduled')
    end

    def pending
      render_filtered_evaluations('scheduled')
    end

    def completed
      render_filtered_evaluations('completed')
    end

    def needs_followup
      render_filtered_evaluations('needs_followup')
    end

    def show
      EmailDelivery::Visibility.preload([@evaluation])
      prepare_show_context
    end

    def new
      @evaluation = current_user.evaluations.build
    end

    def edit
      # set_evaluation supplies the scoped record before implicit rendering.
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
      unless supplemental_notes_update?
        prepare_show_context
        flash.now[:alert] = 'This evaluation action must use the appropriate lifecycle control.'
        render :show, status: :unprocessable_content
        return
      end

      if @evaluation.update(supplemental_notes_params)
        redirect_to evaluators_evaluation_path(@evaluation), notice: 'Evaluation updated successfully.'
      else
        # Supplemental notes come from the show page. Return validation errors there.
        prepare_show_context
        flash.now[:alert] = "Failed to update evaluation: #{@evaluation.errors.full_messages.to_sentence}"
        render :show, status: :unprocessable_content
      end
    end

    def schedule
      result = ::Evaluations::ScheduleService.new(@evaluation, current_user, schedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        @evaluation.reload
        prepare_show_context
        flash.now[:alert] = "Failed to schedule evaluation: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def reschedule
      result = ::Evaluations::RescheduleService.new(@evaluation, current_user, reschedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        @evaluation.reload
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
        @evaluation.reload
        prepare_show_context
        flash.now[:alert] = "Failed to submit evaluation: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def cancel
      result = ::Evaluations::CancelService.new(@evaluation, current_user, evaluation_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        @evaluation.reload
        prepare_show_context
        flash.now[:alert] = "Failed to cancel evaluation: #{result.message}"
        render :show, status: :unprocessable_content
      end
    end

    def no_show
      result = ::Evaluations::NoShowService.new(@evaluation, current_user, evaluation_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        @evaluation.reload
        prepare_show_context
        flash.now[:alert] = "Failed to mark evaluation as no-show: #{result.message}"
        render :show, status: :unprocessable_content
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

    def set_evaluation
      @evaluation = if current_user.admin?
                      Evaluation.find(params[:id])
                    else
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

    def supplemental_notes_params
      params.expect(evaluation: [:post_completion_notes])
    end

    def supplemental_notes_update?
      params.fetch(:evaluation, {}).keys.map(&:to_s) == %w[post_completion_notes]
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

    def render_filtered_evaluations(status)
      @current_scope = current_user.admin? && params[:scope] != 'mine' ? 'all' : 'mine'
      @current_status = status if Evaluation.statuses.key?(status) || status == 'needs_followup'
      @evaluations = filter_evaluations(@current_scope, @current_status)

      render :index
    end

    def filter_evaluations(scope, status)
      base_query = if scope == 'all' && current_user.admin?
                     Evaluation.all
                   else
                     Evaluation.where(evaluator_id: current_user.id)
                   end

      filtered_query = case status
                       when 'scheduled'
                         base_query.active
                       when 'needs_followup'
                         base_query.needing_followup
                       else
                         status.present? ? base_query.where(status: status) : base_query
                       end

      ordering = case status
                 when 'completed'
                   { evaluation_date: :desc }
                 when 'scheduled', 'confirmed'
                   { evaluation_date: :asc }
                 when 'requested'
                   { created_at: :desc }
                 else
                   { updated_at: :desc }
                 end

      filtered_query.order(ordering).includes(:constituent)
    end

    def assigned_evaluator?
      @evaluation&.evaluator_id == current_user&.id
    end
  end
end
