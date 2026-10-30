# frozen_string_literal: true

module Admin
  # Assigns, transfers and removes the trainer coverage of an application.
  class ApplicationTrainersController < BaseController
    include LoadsApplication
    include PractitionerSelection

    def assign_trainer
      trainer = selected_practitioner(:can_train, :trainer_id)
      result = Applications::TrainerAssignment.assign(@application, trainer, actor: current_user)

      finish(result, pass: t('admin.applications.assign_trainer.trainer_assign_pass'),
                     fail: t('admin.applications.assign_trainer.trainer_assign_fail'),
                     warning: 'Saved. A training notice could not be queued. Do not repeat the assignment.')
    end

    def reassign_trainer
      trainer = selected_practitioner(:can_train, :trainer_id)
      result = Applications::TrainerAssignment.reassign(@application, trainer, actor: current_user,
                                                                               expected_version: params[:expected_version].to_s)

      finish(result, pass: t('admin.applications.reassign_trainer.trainer_reassign_pass'),
                     fail: t('admin.applications.reassign_trainer.trainer_reassign_fail'),
                     warning: 'Saved. A training notice could not be queued. Do not repeat the reassignment.')
    end

    def unassign_trainer
      result = Applications::TrainerAssignment.unassign(@application, actor: current_user, reason: params[:unassign_reason])

      finish(result, pass: t('admin.applications.unassign_trainer.trainer_unassign_pass'),
                     fail: t('admin.applications.unassign_trainer.trainer_unassign_fail'),
                     warning: 'Coverage removed. A cancellation notice could not be queued. Do not repeat the removal.')
    end

    private

    # A saved change whose notice could not be queued still succeeds, with a warning not to repeat it.
    def finish(result, pass:, fail:, warning:)
      if result.success?
        flash[:alert] = warning if result.data[:notification_outcomes].any?(&:warning?)
        redirect_to admin_application_path(@application), notice: pass
      else
        redirect_to admin_application_path(@application), alert: result.message.presence || fail
      end
    end
  end
end
