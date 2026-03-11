# frozen_string_literal: true

class MedicalCertificationFormsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    application = find_application_from_signed_id!
    send_form_pdf_for(application)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    head :not_found
  rescue StandardError => e
    Rails.logger.error("Failed to deliver medical certification form: #{e.message}")
    head :unprocessable_entity
  end

  private

  def find_application_from_signed_id!
    Application.find_signed!(params[:signed_id], purpose: :medical_certification)
  end

  def send_form_pdf_for(application)
    pregenerated_path = Rails.root.join('app/assets/pdfs/medical_certification_form.pdf')

    if File.exist?(pregenerated_path)
      send_file pregenerated_path,
                filename: "medical_certification_form_#{application.id}.pdf",
                type: 'application/pdf',
                disposition: 'attachment'
      return
    end

    send_data generated_pdf_content(application),
              filename: "medical_certification_form_#{application.id}.pdf",
              type: 'application/pdf',
              disposition: 'attachment'
  end

  def generated_pdf_content(application)
    Prawn::Document.new.tap do |pdf|
      pdf.font 'Helvetica'
      pdf.text 'Disability Certification Form', size: 18, style: :bold, align: :center
      pdf.move_down 20
      pdf.text "Applicant: #{application.constituent_full_name}"
      dob = application.user&.date_of_birth&.strftime('%B %d, %Y') || 'N/A'
      pdf.text "DOB: #{dob}"
      pdf.move_down 10
      pdf.text 'Provider Information', style: :bold
      pdf.text "Name: #{application.medical_provider_name || 'N/A'}"
      pdf.text "Email: #{application.medical_provider_email || 'N/A'}"
      pdf.text "Phone: #{application.medical_provider_phone || 'N/A'}"
      pdf.text "Fax: #{application.medical_provider_fax}" if application.respond_to?(:medical_provider_fax) && application.medical_provider_fax.present?
      pdf.move_down 20
      pdf.text 'Please complete and return the attached certification.'
    end.render
  end
end
