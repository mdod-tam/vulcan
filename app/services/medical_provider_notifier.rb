# frozen_string_literal: true

# Service for notifying medical providers through different communication channels
class MedicalProviderNotifier
  class NotificationError < StandardError; end

  attr_reader :application, :proof_review

  def initialize(application, proof_review = nil)
    @application = application
    @proof_review = proof_review
    @fax_service = FaxService.new
  end

  # Notify the medical provider about a rejected certification
  # Attempts fax delivery when a provider fax number is present.
  # Email delivery for this rejection event is handled via NotificationService.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @return [Boolean] Whether the notification was sent successfully
  def send_certification_rejection_notice(rejection_reason:, admin:)
    Rails.logger.info "Notifying medical provider about certification rejection for Application ID: #{application.id}"

    log_audit_event(rejection_reason, admin)
    delivery_result = attempt_notification_delivery(rejection_reason, admin)

    handle_delivery_result(delivery_result, rejection_reason, admin)
  end

  private

  # Log the audit event for the rejection
  def log_audit_event(rejection_reason, admin)
    AuditEventService.log(
      action: 'medical_certification_rejected',
      actor: admin,
      auditable: application,
      metadata: {
        rejection_reason: rejection_reason,
        medical_provider_name: application.medical_provider_name
      }
    )
  end

  # Attempt to deliver notification via available channels
  def attempt_notification_delivery(rejection_reason, _admin)
    # This method attempts fax delivery and returns fax delivery status.
    try_fax_delivery(rejection_reason)
  end

  # Try to deliver via fax if fax number is available
  def try_fax_delivery(rejection_reason)
    return failure_result if application.medical_provider_fax.blank?

    notify_by_fax(rejection_reason)
  end

  # Handle the result of delivery attempts
  def handle_delivery_result(delivery_result, _rejection_reason, _admin)
    return false unless delivery_result[:success]

    # Update the notification record created during rejection processing with fax metadata.
    update_notification_metadata(delivery_result)
    true
  rescue StandardError => e
    Rails.logger.error "Failed to handle delivery result for Application ID: #{application.id} - #{e.message}"
    false
  end

  # Update existing notification with delivery metadata
  def update_notification_metadata(delivery_result)
    # Find the notification created by the attachment service
    notification = Notification.where(
      notifiable: application,
      action: 'medical_certification_rejected'
    ).order(created_at: :desc).first

    return unless notification

    # Update metadata with delivery information
    updated_metadata = (notification.metadata || {}).merge(
      'delivery_method' => delivery_result[:method],
      'notification_methods' => notification_methods
    )

    case delivery_result[:method]
    when 'fax'
      updated_metadata['fax_sid'] = delivery_result[:fax_sid] if delivery_result[:fax_sid]
      updated_metadata['blob_id'] = delivery_result[:blob_id] if delivery_result[:blob_id]
    when 'email'
      updated_metadata['message_id'] = delivery_result[:message_id] if delivery_result[:message_id]
    end

    notification.update!(metadata: updated_metadata)
    Rails.logger.info "Updated notification #{notification.id} with delivery metadata"
  end

  # Return a standard failure result
  def failure_result
    { success: false }
  end

  # Notify the medical provider using fax
  # @param rejection_reason [String] The reason for rejection
  # @return [Hash] Hash containing success status and fax_sid
  def notify_by_fax(rejection_reason)
    pdf_path = generate_fax_pdf(rejection_reason)
    return failure_result_with_fax_sid unless pdf_path

    # Upload PDF to ActiveStorage for public URL access
    blob = upload_pdf_to_storage(pdf_path)
    return failure_result_with_fax_sid unless blob

    # Generate public URL for Twilio
    media_url = generate_blob_url(blob)
    return failure_result_with_fax_sid unless media_url

    # Send fax with public URL
    result = send_fax_document_via_url(media_url)
    # Store blob ID in result for webhook cleanup (don't purge here)
    result[:blob_id] = blob.id if result[:success]
    result
  ensure
    cleanup_temp_file(pdf_path)
  end

  # Upload PDF to ActiveStorage for public access
  def upload_pdf_to_storage(pdf_path)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: File.open(pdf_path),
      filename: "cert_rejection_#{application.id}_#{Time.now.to_i}.pdf",
      content_type: 'application/pdf'
    )
    Rails.logger.info "Uploaded fax PDF to ActiveStorage, blob ID: #{blob.id}"
    blob
  rescue StandardError => e
    Rails.logger.error "Failed to upload PDF to storage for Application ID: #{application.id} - #{e.message}"
    nil
  end

  # Generate public blob URL for Twilio
  def generate_blob_url(blob)
    # Host must be configured in config/environments/*.rb:
    # config.action_mailer.default_url_options = { host: 'your-domain.com' }
    host = Rails.application.config.action_mailer.default_url_options[:host]

    if host.blank?
      Rails.logger.error 'Host not configured for blob URLs - cannot generate fax media URL'
      return nil
    end

    Rails.application.routes.url_helpers.rails_blob_url(blob, host: host)
  rescue StandardError => e
    Rails.logger.error "Failed to generate blob URL for Application ID: #{application.id} - #{e.message}"
    nil
  end

  # Send the fax document via public URL
  def send_fax_document_via_url(media_url)
    fax_result = @fax_service.send_fax(
      to: application.medical_provider_fax,
      media_url: media_url,
      options: fax_options
    )

    handle_fax_result(fax_result)
  rescue FaxService::FaxError => e
    Rails.logger.error "Fax sending error for Application ID: #{application.id} - #{e.message}"
    failure_result_with_fax_sid
  rescue StandardError => e
    Rails.logger.error "Unexpected error sending fax for Application ID: #{application.id} - #{e.message}"
    failure_result_with_fax_sid
  end

  # Handle the result from fax service
  def handle_fax_result(fax_result)
    return failure_result_with_fax_sid unless fax_result

    fax_sid = fax_result.sid
    Rails.logger.info "Fax successfully sent to medical provider for Application ID: #{application.id} - Fax SID: #{fax_sid}"
    { success: true, method: 'fax', fax_sid: fax_sid }
  end

  # Get fax sending options
  def fax_options
    {
      quality: 'fine',
      status_callback: Rails.application.routes.url_helpers.webhooks_twilio_fax_status_url(
        host: Rails.application.config.action_mailer.default_url_options[:host]
      )
    }
  end

  # Clean up temporary PDF file
  def cleanup_temp_file(pdf_path)
    FileUtils.rm_f(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  # Return failure result with fax_sid field
  def failure_result_with_fax_sid
    { success: false, fax_sid: nil }
  end

  # Generate a PDF document for faxing
  # @param rejection_reason [String] The reason for rejection
  # @return [String, nil] The path to the generated PDF, or nil if generation failed
  def generate_fax_pdf(rejection_reason)
    temp_file_path = pdf_temp_file_path

    Prawn::Document.generate(temp_file_path) do |pdf|
      add_pdf_header(pdf)
      add_applicant_info(pdf)
      add_rejection_details(pdf, rejection_reason)
      add_remaining_attempts(pdf)
      add_submission_instructions(pdf)
      add_pdf_footer(pdf)
    end

    temp_file_path
  rescue StandardError => e
    Rails.logger.error "Error generating PDF for Application ID: #{application.id} - #{e.message}"
    nil
  end

  # Generate temp file path for PDF
  def pdf_temp_file_path
    Rails.root.join('tmp', "certification_rejection_#{application.id}_#{Time.now.to_i}.pdf")
  end

  # Add header section to PDF
  def add_pdf_header(pdf)
    pdf.text 'Maryland Accessible Telecommunications', size: 18, style: :bold
    pdf.move_down 10
    pdf.text 'Disability Certification Form for Applicant needs Updates', size: 16, style: :bold
    pdf.move_down 20
  end

  # Add applicant information section to PDF
  def add_applicant_info(pdf)
    pdf.text "Name: #{application.user.full_name}", size: 12
    pdf.text "Application ID: #{application.id}", size: 12
    pdf.move_down 20
  end

  # Add rejection reason details to PDF
  def add_rejection_details(pdf, rejection_reason)
    pdf.text 'Reason for Revision:', size: 14, style: :bold
    pdf.move_down 5
    pdf.text rejection_reason, size: 12
    pdf.move_down 20
  end

  # Add remaining attempts information to PDF
  def add_remaining_attempts(pdf)
    remaining_attempts = 8 - application.total_rejections
    pdf.text "Remaining Attempts: #{remaining_attempts}", size: 12
    pdf.move_down 20
  end

  # Add submission instructions to PDF
  def add_submission_instructions(pdf)
    pdf.text 'Instructions for Submitting Revised Documentation:', size: 14, style: :bold
    pdf.move_down 5
    pdf.text '1. Fax the revised certification to: 410-767-4276', size: 12
    pdf.text '2. Or reply to this communication with the revised certification attached', size: 12
    pdf.move_down 20
  end

  # Add footer section to PDF
  def add_pdf_footer(pdf)
    pdf.text 'Thank you for your assistance in helping this applicant access needed telecommunications services.', size: 12
    pdf.text 'For questions, please contact: mat.program1@maryland.gov', size: 12
  end

  # Get the contact methods that were available for the medical provider
  # @return [Array<String>] The available notification methods
  def notification_methods
    methods = []
    methods << 'fax' if application.medical_provider_fax.present?
    methods << 'email' if application.medical_provider_email.present?
    methods
  end
end
