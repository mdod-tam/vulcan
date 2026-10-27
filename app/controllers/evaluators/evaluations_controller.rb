# frozen_string_literal: true

module Evaluators
  class EvaluationsController < ApplicationController
    include ViewerLocale

    around_action :with_viewer_locale

    FORM_ERROR_FIELDS = {
      schedule: %i[evaluation_date location notes],
      reschedule: %i[evaluation_date location reschedule_reason],
      submit_report: ::Evaluations::SubmissionService::REPORT_FIELDS,
      cancel: %i[notes], no_show: %i[notes], save_working_notes: %i[working_notes],
      supplemental_notes: %i[post_completion_notes]
    }.transform_values(&:freeze).freeze
    FORM_ERROR_FIELD_ALIASES = {
      products_tried: :products_tried_inputs, recommended_products: :recommended_product_ids,
      attendees: :attendees_field
    }.freeze

    before_action :authenticate_user!
    before_action :require_evaluator!
    before_action :set_evaluation,
                  except: %i[index pending completed requested scheduled needs_followup filter]
    before_action :authorize_evaluation_mutation!,
                  only: %i[update schedule reschedule submit_report cancel no_show save_working_notes]

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

    def application_details
      if current_user.admin?
        redirect_to admin_application_path(@evaluation.application)
      else
        @contact_context = ::Applications::ContactContext.new(application: @evaluation.application)
      end
    end

    def update
      unless @evaluation.status_completed? && supplemental_notes_update?
        action = if @evaluation.status_completed?
                   :supplemental_notes
                 elsif @evaluation.can_complete?
                   :submit_report
                 else
                   :save_working_notes
                 end
        render_lifecycle_failure(action, {}, 'This evaluation action must use the appropriate lifecycle control.')
        return
      end

      result = ::Evaluations::SupplementalNotesService.new(@evaluation, current_user, supplemental_notes_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:supplemental_notes, supplemental_notes_params, "Failed to update evaluation: #{result.message}")
      end
    end

    def schedule
      result = ::Evaluations::ScheduleService.new(@evaluation, current_user, schedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:schedule, schedule_params, "Failed to schedule evaluation: #{result.message}")
      end
    end

    def reschedule
      result = ::Evaluations::RescheduleService.new(@evaluation, current_user, reschedule_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:reschedule, reschedule_params, "Failed to reschedule evaluation: #{result.message}")
      end
    end

    def submit_report
      result = ::Evaluations::SubmissionService.new(@evaluation, params, actor: current_user).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:submit_report, report_form_params, "Failed to submit evaluation: #{result.message}")
      end
    end

    def cancel
      result = ::Evaluations::CancelService.new(@evaluation, current_user, outcome_notes_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:cancel, outcome_notes_params, "Failed to cancel evaluation: #{result.message}")
      end
    end

    def no_show
      result = ::Evaluations::NoShowService.new(@evaluation, current_user, outcome_notes_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:no_show, outcome_notes_params, "Failed to mark evaluation as no-show: #{result.message}")
      end
    end

    def save_working_notes
      result = ::Evaluations::WorkingNotesService.new(@evaluation, current_user, working_notes_params).call

      if result.success?
        redirect_to evaluators_evaluation_path(@evaluation), notice: result.message
      else
        render_lifecycle_failure(:save_working_notes, working_notes_params, "Failed to save working notes: #{result.message}")
      end
    end

    private

    def prepare_show_context
      @evaluation_form_values ||= {}
      @evaluation_form_errors ||= {}
      @can_manage_evaluation = assigned_evaluator?
      @contact_context = ::Applications::ContactContext.new(application: @evaluation.application)
      @activity_logs = ::Evaluations::AuditLogBuilder.new(@evaluation).build
      @available_products = Product.order(:name).to_a
      @recommendation_products = @available_products.reject(&:archived?)
    end

    def render_lifecycle_failure(action, form_values, message)
      form_errors = evaluation_form_errors(@evaluation.errors, action)
      form_errors[:base] = [message] if form_errors.empty?
      @evaluation.reload
      unless current_user.admin? || assigned_evaluator?
        redirect_to evaluators_evaluations_path, alert: 'Evaluation not found.'
        return
      end

      @evaluation_form_values = { action => form_values.to_h.with_indifferent_access }
      @evaluation_form_errors = { action => form_errors }
      prepare_show_context
      render :show, status: :unprocessable_content
    end

    def evaluation_form_errors(errors, action)
      errors.each_with_object({}) do |error, form_errors|
        field = FORM_ERROR_FIELD_ALIASES.fetch(error.attribute, error.attribute)
        field = :base unless FORM_ERROR_FIELDS.fetch(action).include?(field)
        (form_errors[field] ||= []) << error.full_message
      end
    end

    def set_evaluation
      @evaluation = if current_user.admin?
                      Evaluation.find(params[:id])
                    else
                      current_user.assigned_evaluations.find(params[:id])
                    end
    rescue ActiveRecord::RecordNotFound
      redirect_to evaluators_evaluations_path, alert: 'Evaluation not found.'
    end

    def supplemental_notes_params
      params.expect(evaluation: [:post_completion_notes])
    end

    def outcome_notes_params
      params.expect(evaluation: [:notes])
    end

    def working_notes_params
      params.expect(evaluation: [:working_notes])
    end

    def report_form_params
      ::Evaluations::SubmissionService.report_params(params)
    end

    def supplemental_notes_update?
      params.fetch(:evaluation, {}).keys.map(&:to_s) == %w[post_completion_notes]
    end

    def schedule_params
      params.expect(evaluation: %i[evaluation_date location notes])
    end

    def reschedule_params
      params.expect(evaluation: %i[evaluation_date location reschedule_reason])
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

      return filtered_query.by_report_submission.includes(:constituent) if status == 'completed'

      ordering = case status
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
