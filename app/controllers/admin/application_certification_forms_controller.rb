# frozen_string_literal: true

module Admin
  # Sends the disability certification form out for an application: a certification request, a DocuSeal signing
  # request, or a printed copy queued for mailing.
  class ApplicationCertificationFormsController < BaseController
    include LoadsApplication

    def resend_disability_certification
      result = Applications::DisabilityCertificationService.new(application: @application, actor: current_user).request_certification

      if result.success?
        redirect_to admin_application_path(@application),
                    notice: t('admin.applications.resend_disability_certification.c_request_pass')
      else
        redirect_to admin_application_path(@application),
                    alert: "Failed to process certification request: #{result.message}"
      end
    end

    def send_document_signing_request
      result = DocumentSigning::SubmissionService.new(
        application: @application,
        actor: current_user,
        service: 'docuseal'
      ).call

      if result.success?
        redirect_to admin_application_path(@application),
                    notice: t('admin.applications.send_document_signing_request.d_sign_request_pass')
      elsif result.data.is_a?(Hash) && result.data[:delivery_suppressed]
        # Delivery suppression permits staff to print the form.
        redirect_to admin_application_path(@application), alert: result.message
      else
        redirect_to admin_application_path(@application),
                    alert: "Failed to send signing request: #{result.message}"
      end
    end

    # Without app/assets/pdfs/disability_certification_form.pdf, generate a PDF with application and provider details.
    def queue_disability_certification_form
      result = Applications::DisabilityCertificationPdfService.new(
        application: @application,
        actor: current_user,
        pdf_source: pdf_source,
        request_key: params.require(:operation_id)
      ).call

      respond_to do |format|
        if result.success?
          queue_notice = t('admin.applications.queue_disability_certification_form.queue_print_pass')
          flash.now[:notice] = helpers.safe_join([queue_notice, ' ', helpers.link_to('View print queue', admin_print_queue_index_path)])
          format.turbo_stream do
            render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
          end
          format.html { redirect_to admin_print_queue_index_path, notice: queue_notice }
        else
          flash.now[:alert] = result.message || 'Failed to queue DCF for printing.'
          format.turbo_stream do
            render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash'), status: :unprocessable_content
          end
          format.html { redirect_to admin_application_path(@application), alert: result.message || 'Failed to queue DCF for printing.' }
        end
      end
    end

    private

    def pdf_source
      pregenerated_path = Rails.root.join('app/assets/pdfs/disability_certification_form.pdf')
      File.exist?(pregenerated_path) ? { type: :pregenerated, source: pregenerated_path } : { type: :generated }
    end
  end
end
