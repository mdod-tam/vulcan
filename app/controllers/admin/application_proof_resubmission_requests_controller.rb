# frozen_string_literal: true

module Admin
  class ApplicationProofResubmissionRequestsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      result = Applications::RequestProofResubmission.new(
        application: @application,
        actor: current_user,
        proof_type: params.fetch(:proof_type),
        recipient_ids: recipient_ids_param,
        channel_overrides: channel_overrides_param
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

    def recipient_ids_param
      return nil unless params.key?(:recipient_ids)

      Array(params[:recipient_ids])
    end

    def channel_overrides_param
      raw_overrides = params[:channel_overrides]
      return {} if raw_overrides.blank?

      raw_overrides.respond_to?(:to_unsafe_h) ? raw_overrides.to_unsafe_h : raw_overrides.to_h
    end
  end
end
