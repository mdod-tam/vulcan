# frozen_string_literal: true

class MedicalCertificationFormsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    send_form_pdf
  rescue Errno::ENOENT
    head :not_found
  rescue StandardError => e
    Rails.logger.error("Failed to deliver medical certification form: #{e.message}")
    head :unprocessable_entity
  end

  private

  def send_form_pdf
    form_path = Rails.root.join('app/assets/pdfs/medical_certification_form.pdf')

    send_file form_path,
              filename: 'medical_certification_form.pdf',
              type: 'application/pdf',
              disposition: 'attachment'
  end
end
