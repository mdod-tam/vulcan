# frozen_string_literal: true

module Admin
  class ApplicationProofResubmissionRequestsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      result = Applications::RequestProofResubmission.new(
        application: @application,
        actor: current_user,
        proof_type: proof_resubmission_params.fetch(:proof_type),
        recipient_ids: proof_resubmission_params[:recipient_ids],
        channel_overrides: (proof_resubmission_params[:channel_overrides] || {}).to_h
      ).call

      if result.success?
        redirect_to admin_application_path(@application), notice: result.message
      else
        redirect_to admin_application_path(@application), alert: result.message.presence || failure_message
      end
    rescue StandardError => e
      Rails.logger.error("Secure proof resubmission request failed for application #{@application&.id}: #{e.message}")
      redirect_to admin_application_path(@application), alert: failure_message
    end

    private

    def failure_message
      I18n.t('admin.applications.proof_resubmission_requests.create.failure')
    end

    def proof_resubmission_params
      params.permit(:proof_type, recipient_ids: [], channel_overrides: {})
    end
  end
end
