# frozen_string_literal: true

class MedicalCertificationFormsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    signed_id = params[:signed_id].to_s
    application = find_application_from_signed_id!(signed_id)
    return head :not_found unless MedicalCertificationFormLink.allowed_for?(application)
    return head :not_found if MedicalCertificationFormLink.consumed?(application, signed_id)

    MedicalCertificationFormLink.consume!(application, signed_id)
    send_form_pdf_for(application)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    head :not_found
  rescue StandardError => e
    Rails.logger.error("Failed to deliver medical certification form: #{e.message}")
    head :unprocessable_entity
  end

  private

  def find_application_from_signed_id!(signed_id)
    MedicalCertificationFormLink.find_application!(signed_id)
  end

  def send_form_pdf_for(_application)
    form_path = Rails.root.join('app/assets/pdfs/medical_certification_form.pdf')

    send_file form_path,
              filename: 'medical_certification_form.pdf',
              type: 'application/pdf',
              disposition: 'attachment'
  end
end
