# frozen_string_literal: true

module Trainers
  class TrainingSessionsController < Trainers::BaseController
    FORM_FIELDS = {
      schedule: %i[scheduled_for location internal_notes],
      schedule_additional: %i[scheduled_for location internal_notes],
      follow_up: %i[scheduled_for location internal_notes reschedule_reason],
      reschedule: %i[scheduled_for location reschedule_reason],
      complete: %i[completed_at product_trained_on_id duration_hours internal_notes constituent_summary summary_locale],
      cancel: %i[cancellation_reason cancellation_initiator],
      no_show: %i[no_show_notes]
    }.freeze

    FORM_ERROR_FIELD_ALIASES = { product_trained_on: :product_trained_on_id }.freeze

    before_action :set_training_session, only: %i[show complete schedule schedule_additional reschedule cancel no_show]
    before_action :authorize_training_session_mutation!, only: %i[complete schedule schedule_additional reschedule cancel no_show]

    def index
      render_filtered_sessions(params[:status])
    end

    def filter
      render_filtered_sessions(params[:status])
    end

    def requested
      render_filtered_sessions('requested')
    end

    def scheduled
      render_filtered_sessions('scheduled')
    end

    def completed
      render_filtered_sessions('completed')
    end

    def needs_followup
      render_filtered_sessions('needs_followup')
    end

    def show
      prepare_show_context
    end

    def complete
      run_training_command(:complete, ::TrainingSessions::CompleteService)
    end

    def schedule
      run_training_command(:schedule, ::TrainingSessions::ScheduleService)
    end

    def schedule_additional
      run_training_command(:schedule_additional, ::TrainingSessions::ScheduleAdditionalService)
    end

    def reschedule
      run_training_command(:reschedule, ::TrainingSessions::RescheduleService)
    end

    def cancel
      run_training_command(:cancel, ::TrainingSessions::CancelService)
    end

    def no_show
      run_training_command(:no_show, ::TrainingSessions::NoShowService)
    end

    private

    def run_training_command(action, service)
      attempted = params.permit(*FORM_FIELDS.fetch(action))
      result = service.new(@training_session, current_user, attempted).call
      if result.success?
        outcome = result.data[:notification_outcome]
        flash[:alert] = t('training_feedback.save_warning') if outcome&.warning?
        redirect_to trainers_training_session_path(result.data[:training_session] || @training_session),
                    notice: result.message, status: :see_other
      else
        render_training_failure(action, attempted, result.message, result.data&.[](:training_session))
      end
    end

    def render_training_failure(action, attempted, message, result_record = nil)
      errors = (result_record || @training_session).errors.each_with_object({}) do |error, mapped|
        attribute = FORM_ERROR_FIELD_ALIASES.fetch(error.attribute, error.attribute)
        key = FORM_FIELDS.fetch(action).include?(attribute) ? attribute : :base
        (mapped[key] ||= []) << error.full_message
      end
      errors[:base] = [message] if errors.empty?
      @training_session.reload
      unless current_user.admin? || current_assignment? || @training_session.status_completed?
        redirect_to trainers_training_sessions_path, alert: t('training_feedback.coverage_changed'), status: :see_other
        return
      end
      @training_form_values = { action => attempted.to_h.with_indifferent_access }
      @training_form_errors = { action => errors }
      @failed_training_action = action
      prepare_show_context
      render 'trainers/training_sessions/show', status: :unprocessable_content
    end

    def prepare_show_context
      @training_form_values ||= {}
      @training_form_errors ||= {}
      @application = @training_session.application
      @constituent = @application.user
      @session_number = @training_session.appointment_number
      @can_manage_training_session = current_assignment?
      @current_training_access = current_user.admin? || @can_manage_training_session
      return unless @current_training_access

      @contact_context = ::Applications::ContactContext.new(application: @application)
      @max_training_sessions = @application.max_training_sessions
      @completed_training_sessions_count = @application.completed_training_sessions_count
      @remaining_training_session_slots = @application.remaining_training_sessions
      @reserved_training_sessions_count = @application.reserved_training_sessions_count
      @open_training_sessions = @application.training_sessions.assigned_or_scheduled.includes(:trainer).order(:created_at, :id)
      @previous_training_sessions = @training_session.previous_completed_sessions.includes(:trainer, :product_trained_on)
      @evaluation_recommendations = @application.evaluations.completed_sessions.by_report_submission.includes(:recommended_products).first
      @known_products = ::Applications::ProductHistory.new(applications: Application.where(id: @application.id)).products
      @available_products = @known_products + Product.order(:name, :id).where.not(id: @known_products.map(&:id)).to_a
      @activity_logs = ::TrainingSessions::AuditLogBuilder.new(@training_session).build
      @training_notifications = Notification.where(notifiable: @training_session).order(created_at: :desc, id: :desc)
      EmailDelivery::Visibility.preload(@training_notifications)
      @unlinked_training_attempts = @training_session.email_delivery_attempts.where(notification_id: nil).includes(:delivery_owner).order(:id)
    end

    def render_filtered_sessions(status)
      @current_scope = current_user.admin? && params[:scope] != 'mine' ? 'all' : 'mine'
      @current_status = status if TrainingSession.statuses.key?(status.to_s) || status == 'needs_followup'
      @trainer_filter = User.find_by(id: params[:trainer_id]) if current_user.admin? && params[:trainer_id].present?
      query = if current_user.admin? && @current_scope == 'all'
                TrainingSession.all
              else
                TrainingSession.where(trainer_id: current_user.id).joins(:application)
                               .where('applications.assigned_trainer_id = :trainer OR training_sessions.status = :completed',
                                      trainer: current_user.id, completed: TrainingSession.statuses.fetch('completed'))
              end
      query = query.where(trainer_id: @trainer_filter.id) if @trainer_filter
      query = filtered_status(query, @current_status)
      @pagy, @training_sessions = pagy(query.includes(application: :user), items: 20)
      render :index
    end

    def filtered_status(query, status)
      case status
      when 'scheduled'
        query.where(status: %i[scheduled confirmed]).order(:scheduled_for, :id)
      when 'completed'
        query.where(status: :completed).order(completed_at: :desc, id: :desc)
      when 'needs_followup', 'cancelled', 'no_show'
        query.merge(TrainingSession.ordered_followup_per_application(status == 'needs_followup' ? %i[cancelled no_show] : status))
             .joins(:application).where('applications.assigned_trainer_id = training_sessions.trainer_id')
      else
        query = query.where(status: status) if status.present?
        query.order(created_at: :desc, id: :desc)
      end
    end

    def set_training_session
      scope = if current_user.admin?
                TrainingSession.all
              else
                TrainingSession.where(trainer_id: current_user.id)
              end
      @training_session = scope.find(params[:id] || params[:training_session_id])
      return if current_user.admin? || current_assignment? || @training_session.status_completed?

      raise ActiveRecord::RecordNotFound
    end

    def authorize_training_session_mutation!
      return if current_assignment?

      redirect_to trainers_training_session_path(@training_session),
                  alert: t('trainers.training_sessions.flash.assigned_trainer_only'), status: :see_other
    end

    def current_assignment?
      @training_session.trainer_id == current_user.id && @training_session.application.current_trainer?(current_user)
    end
  end
end
