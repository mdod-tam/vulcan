# frozen_string_literal: true

module Admin
  class ApplicationCertificationUploadRequestsController < BaseController
    include LoadsNestedApplication

    before_action :load_nested_application

    def create
      result = Applications::RequestCertificationUpload.new(
        application: @application,
        actor: current_user,
        deliver_email: true
      ).call

      if result.success?
        redirect_to admin_application_path(@application),
                    status: :see_other,
                    notice: t('admin.applications.certification_upload_requests.create.success')
      else
        redirect_to admin_application_path(@application),
                    status: :see_other,
                    alert: result.message.presence || t('admin.applications.certification_upload_requests.create.failure')
      end
    rescue StandardError => e
      Rails.logger.error("Secure certification upload request failed for application #{@application&.id}: #{e.class.name}")
      redirect_to admin_application_path(@application),
                  status: :see_other,
                  alert: t('admin.applications.certification_upload_requests.create.failure')
    end

    private

  end
end
