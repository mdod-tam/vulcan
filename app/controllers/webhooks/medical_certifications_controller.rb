# frozen_string_literal: true

module Webhooks
  class MedicalCertificationsController < BaseController
    def create
      application = Application.find_by!(
        medical_provider_email: provider_email,
        status: :awaiting_dcf
      )

      certification = create_certification(application)

      head :ok
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def valid_payload?
      params[:provider_email].present? &&
        params[:document_url].present? &&
        params[:constituent_name].present?
    end

    def create_certification(application)
      document = URI.open(params[:document_url])
      blob = ActiveStorage::Blob.create_and_upload!(
        io: document,
        filename: params[:original_filename].presence || "certification-#{application.id}.pdf",
        content_type: 'application/pdf'
      )

      MedicalCertificationAttachmentService.attach_certification(
        application: application,
        blob_or_file: blob,
        status: :received,
        admin: User.system_user,
        submission_method: :webhook,
        metadata: certification_metadata
      )

      AuditEventService.log(
        actor: User.system_user,
        action: 'medical_certification_received',
        auditable: application,
        metadata: certification_metadata.merge(
          application_id: application.id,
          submission_method: 'webhook'
        )
      )

      application.update!(last_activity_at: Time.current)
      application
    end

    def provider_email
      params[:provider_email].downcase
    end

    def certification_metadata
      {
        provider_email: provider_email,
        provider_name: params[:provider_name],
        submission_timestamp: Time.current.iso8601,
        original_filename: params[:original_filename],
        webhook_id: params[:webhook_id]
      }
    end
  end
end
