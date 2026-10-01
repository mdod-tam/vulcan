# frozen_string_literal: true

module Applications
  # Generates or attaches a Medical Certification Form (DCF) PDF and enqueues it for printing.
  # - If a pregenerated PDF is available (path or IO provided), it will be attached as-is.
  # - Otherwise, a simple generated PDF with key fields is produced.
  class MedicalCertificationPdfService < BaseService
    attr_reader :application, :actor, :pdf_source

    # @param application [Application]
    # @param actor [User] The admin triggering the action
    # @param pdf_source [Hash] Optional: { type: :pregenerated, source: <IO|String|Pathname> } or { type: :generated }
    def initialize(application:, actor: nil, request_key: SecureRandom.uuid, pdf_source: { type: :generated })
      super()
      @request_key = request_key
      @application = application
      @actor = actor
      @pdf_source = pdf_source || { type: :generated }
    end

    def call
      context = EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form', request_id: @request_key)
      item = Letters::Delivery.queue!(recipient: application.user, application: application,
                                      letter_type: :medical_certification_form, context: context,
                                      actor: actor, request_key: @request_key) { prepare_pdf_tempfile }
      success('DCF queued for printing', item)
    rescue ApplicationMailer::DeliverySkipped => e
      failure(I18n.t('outbound_delivery.delivery_suppressed'), { delivery_suppressed: true, reason: e.reason })
    rescue EmailDelivery::ConfigurationError => e
      failure(e.message, { configuration_error: true })
    rescue StandardError => e
      log_error(e, application_id: application&.id)
      failure('Unexpected error while queuing DCF for printing')
    end

    private

    def prepare_pdf_tempfile
      type = (pdf_source[:type] || :generated).to_sym
      case type
      when :pregenerated
        load_pregenerated_pdf(pdf_source[:source]) || generate_pdf
      else
        generate_pdf
      end
    end

    def load_pregenerated_pdf(io_or_path)
      return nil if io_or_path.nil?

      if io_or_path.respond_to?(:read)
        build_tempfile_from_io(io_or_path)
      else
        path = io_or_path.to_s
        return nil unless File.exist?(path)

        build_tempfile_from_path(path)
      end
    end

    def build_tempfile_from_path(path)
      Tempfile.create(['dcf', '.pdf']).tap do |tf|
        tf.binmode
        File.open(path, 'rb') { |f| IO.copy_stream(f, tf) }
        tf.rewind
      end
    end

    def build_tempfile_from_io(io)
      Tempfile.create(['dcf', '.pdf']).tap do |tf|
        tf.binmode
        IO.copy_stream(io, tf)
        tf.rewind
      end
    end

    def generate_pdf
      pdf = Prawn::Document.new
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

      tf = Tempfile.new(['dcf', '.pdf'])
      tf.binmode
      tf.write(pdf.render)
      tf.rewind
      tf
    end
  end
end
