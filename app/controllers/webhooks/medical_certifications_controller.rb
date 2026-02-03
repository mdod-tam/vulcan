# frozen_string_literal: true

module Webhooks
  class MedicalCertificationsController < BaseController
    def create
      application = Application.find_by!(
        medical_provider_email: provider_email,
        status: :awaiting_dcf
      )

      certification = create_certification(application)
      notify_admins(certification)

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
      ApplicationRecord.transaction do
        # Attach the certification document
        document = URI.open(params[:document_url])
        application.medical_certification.attach(
          io: document,
          filename: "certification-#{application.id}.pdf"
        )

        # Update application status
        application.update!(
          medical_certification_status: :received,
          last_activity_at: Time.current
        )

        # Create an audit trail
        CertificationSubmissionAudit.create!(
          application: application,
          provider_email: provider_email,
          provider_name: params[:provider_name],
          submission_method: 'webhook',
          metadata: certification_metadata
        )

        # Return the updated application
        application
      end
    end

    def notify_admins(certification)
      AdminNotifier.new(
        subject: 'New Medical Certification Received',
        message: "Medical certification received for Application ##{certification.id}",
        level: :info
      ).notify_all
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
