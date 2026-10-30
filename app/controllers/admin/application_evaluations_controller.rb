# frozen_string_literal: true

module Admin
  # Requests an evaluation for an approved application and assigns or transfers its evaluator.
  class ApplicationEvaluationsController < BaseController
    include LoadsApplication
    include PractitionerSelection

    def assign_evaluator
      evaluator = selected_practitioner(:can_evaluate, :evaluator_id)
      result = Applications::EvaluatorAssignment.assign(@application, evaluator, actor: current_user)

      if result.success?
        redirect_to admin_application_path(@application), notice: t('admin.applications.assign_evaluator.eval_assign_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: result.message.presence || t('admin.applications.assign_evaluator.eval_assign_fail')
      end
    end

    def reassign_evaluator
      evaluator = selected_practitioner(:can_evaluate, :evaluator_id)
      result = Applications::EvaluatorAssignment.reassign(@application, evaluator, actor: current_user)

      if result.success?
        redirect_to admin_application_path(@application), notice: 'Evaluator reassigned. Existing appointment details have been preserved.'
      else
        redirect_to admin_application_path(@application), alert: result.message
      end
    end

    # The request timestamp adds an approved application to the evaluation queue.
    # Any evaluation created at or after the request closes it.
    def request_evaluation
      @application.request_evaluation!(actor: current_user)
      redirect_to admin_application_path(@application),
                  notice: 'Evaluation requested. Assign an evaluator when ready.'
    rescue ArgumentError => e
      redirect_to admin_application_path(@application), alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_application_path(@application),
                  alert: e.record.errors.full_messages.to_sentence.presence || e.message
    rescue StandardError => e
      Rails.logger.error "Failed to request evaluation for application #{@application.id}: #{e.class.name}"
      redirect_to admin_application_path(@application), alert: 'Failed to request evaluation.'
    end
  end
end
