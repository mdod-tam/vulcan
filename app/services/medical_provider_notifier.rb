# frozen_string_literal: true

# Service for notifying medical providers through different communication channels
class MedicalProviderNotifier
  class NotificationError < StandardError; end

  REJECTION_ACTION = 'medical_certification_rejected'
  DOCUMENT_SIGNING_METHOD = 'document_signing'
  FAX_METHOD = 'fax'
  EMAIL_METHOD = 'email'

  attr_reader :application, :proof_review

  def initialize(application, proof_review = nil)
    @application = application
    @proof_review = proof_review
    @fax_service = FaxService.new
  end

  # Notify the medical provider about a rejected certification.
  # Uses channel continuity (document signing/email/fax) with fallback on failure.
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @param notification_id [Integer, nil] Existing rejection notification id to enrich with delivery metadata
  # @return [Boolean] Whether the notification was sent successfully
  def send_certification_rejection_notice(rejection_reason:, admin:, notification_id: nil)
    Rails.logger.info "Notifying medical provider about certification rejection for Application ID: #{application.id}"

    log_audit_event(rejection_reason, admin)
    delivery_result = attempt_notification_delivery(rejection_reason, admin)

    handle_delivery_result(delivery_result, notification_id: notification_id)
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
  def attempt_notification_delivery(rejection_reason, admin)
    methods = prioritized_delivery_methods(admin)
    return failure_result(error: 'No contact method available for medical provider') if methods.empty?

    last_failure = nil

    methods.each_with_index do |method, index|
      result = deliver_via_method(method, rejection_reason, admin)
      if result[:success]
        result[:fallback_from] = methods[index - 1] if index.positive?
        return result
      end

      last_failure = result
    end

    last_failure || failure_result(error: 'All provider delivery methods failed')
  end

  def prioritized_delivery_methods(admin)
    methods = [preferred_delivery_method(admin), EMAIL_METHOD, FAX_METHOD].uniq
    methods.select { |method| delivery_method_available?(method, admin) }
  end

  def preferred_delivery_method(admin)
    return DOCUMENT_SIGNING_METHOD if document_signing_preferred? && document_signing_available?(admin)
    return EMAIL_METHOD if email_available?

    FAX_METHOD
  end

  def delivery_method_available?(method, admin)
    case method
    when DOCUMENT_SIGNING_METHOD
      document_signing_available?(admin)
    when EMAIL_METHOD
      email_available?
    when FAX_METHOD
      fax_available?
    else
      false
    end
  end

  def deliver_via_method(method, rejection_reason, admin)
    case method
    when DOCUMENT_SIGNING_METHOD
      notify_by_document_signing(admin)
    when EMAIL_METHOD
      notify_by_email(rejection_reason, admin)
    when FAX_METHOD
      notify_by_fax(rejection_reason)
    else
      failure_result(method: method, error: 'Unsupported delivery method')
    end
  end

  def document_signing_preferred?
    application.document_signing_request_count.to_i.positive? ||
      application.document_signing_requested_at.present? ||
      application.document_signing_submission_id.present? ||
      application.document_signing_status.to_s.in?(%w[sent opened signed declined])
  end

  def document_signing_available?(admin)
    admin.present? && application.medical_provider_email.present?
  end

  def fax_available?
    application.medical_provider_fax.present?
  end

  def email_available?
    application.medical_provider_email.present?
  end

  # Handle the result of delivery attempts
  def handle_delivery_result(delivery_result, notification_id: nil)
    update_notification_metadata(delivery_result, notification_id: notification_id)
    delivery_result[:success]
  rescue StandardError => e
    Rails.logger.error "Failed to handle delivery result for Application ID: #{application.id} - #{e.message}"
    false
  end

  # Update existing notification with delivery metadata
  def update_notification_metadata(delivery_result, notification_id: nil)
    notification = find_rejection_notification(notification_id)

    return unless notification

    updated_metadata = (notification.metadata || {}).merge(
      'notification_methods' => notification_methods,
      'provider_notification_attempted_at' => Time.current.iso8601
    )

    if delivery_result[:success]
      updated_metadata['delivery_method'] = delivery_result[:method]
      apply_success_metadata(updated_metadata, delivery_result)
    elsif delivery_result[:error].present?
      updated_metadata['provider_notification_error'] = delivery_result[:error]
    end

    notification.update!(metadata: updated_metadata)
    Rails.logger.info "Updated notification #{notification.id} with delivery metadata"
  end

  def find_rejection_notification(notification_id)
    if notification_id.present?
      notification = Notification.find_by(
        id: notification_id,
        notifiable: application,
        action: REJECTION_ACTION
      )

      return notification if notification.present?

      Rails.logger.warn "Rejection notification #{notification_id} not found for Application ID: #{application.id}; falling back to latest match"
    end

    scope = Notification.where(notifiable: application, action: REJECTION_ACTION)
    recent_match = scope.where(created_at: 15.minutes.ago..).order(created_at: :desc).first

    recent_match || scope.order(created_at: :desc).first
  end

  def apply_success_metadata(metadata, delivery_result)
    case delivery_result[:method]
    when DOCUMENT_SIGNING_METHOD
      metadata['document_signing_submission_id'] = delivery_result[:document_signing_submission_id] if delivery_result[:document_signing_submission_id].present?
      metadata['document_signing_service'] = delivery_result[:document_signing_service] if delivery_result[:document_signing_service].present?
    when FAX_METHOD
      metadata['fax_sid'] = delivery_result[:fax_sid] if delivery_result[:fax_sid].present?
      metadata['blob_id'] = delivery_result[:blob_id] if delivery_result[:blob_id].present?
    when EMAIL_METHOD
      metadata['message_id'] = delivery_result[:message_id] if delivery_result[:message_id].present?
      metadata['email_fallback_from'] = delivery_result[:fallback_from] if delivery_result[:fallback_from].present?
    end
  end

  # Return a standard failure result
  def failure_result(error: nil, method: nil)
    {
      success: false,
      method: method,
      error: error
    }.compact
  end

  # Notify provider through the same digital-signing channel previously used.
  # @param admin [User] The admin triggering the rejection notification
  # @return [Hash] Delivery result hash
  def notify_by_document_signing(admin)
    service_name = application.document_signing_service.presence || 'docuseal'

    result = DocumentSigning::SubmissionService.new(
      application: application,
      actor: admin,
      service: service_name
    ).call

    if result.success?
      return {
        success: true,
        method: DOCUMENT_SIGNING_METHOD,
        document_signing_submission_id: result.data&.dig('id').to_s,
        document_signing_service: service_name
      }
    end

    failure_result(method: DOCUMENT_SIGNING_METHOD, error: result.message)
  rescue StandardError => e
    Rails.logger.error "Document signing notification error for Application ID: #{application.id} - #{e.message}"
    failure_result(method: DOCUMENT_SIGNING_METHOD, error: e.message)
  end

  # Notify the medical provider using fax
  # @param rejection_reason [String] The reason for rejection
  # @return [Hash] Hash containing success status and fax_sid
  def notify_by_fax(rejection_reason)
    pdf_path = generate_fax_pdf(rejection_reason)
    return failure_result(method: FAX_METHOD, error: 'Failed to generate fax PDF') unless pdf_path

    # Upload PDF to ActiveStorage for public URL access
    blob = upload_pdf_to_storage(pdf_path)
    return failure_result(method: FAX_METHOD, error: 'Failed to upload fax PDF') unless blob

    # Generate public URL for Twilio
    media_url = generate_blob_url(blob)
    unless media_url
      purge_blob(blob)
      return failure_result(method: FAX_METHOD, error: 'Failed to generate fax media URL')
    end

    # Send fax with public URL
    result = send_fax_document_via_url(media_url)

    if result[:success]
      # Store blob ID in result for webhook cleanup (don't purge here)
      result[:blob_id] = blob.id
    else
      purge_blob(blob)
    end

    result
  ensure
    cleanup_temp_file(pdf_path)
  end

  # Notify the medical provider by email
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  # @return [Hash] Delivery result hash
  def notify_by_email(rejection_reason, admin)
    mail = MedicalProviderMailer.with(
      application: application,
      rejection_reason: rejection_reason,
      admin: admin
    ).certification_rejected

    mail.deliver_later
    message_id = mail.message_id

    Rails.logger.info "Email successfully queued for medical provider for Application ID: #{application.id} with message ID: #{message_id}"
    { success: true, method: EMAIL_METHOD, message_id: message_id }
  rescue StandardError => e
    Rails.logger.error "Email sending error for Application ID: #{application.id} - #{e.message}"
    failure_result(method: EMAIL_METHOD, error: e.message)
  end

  # Upload PDF to ActiveStorage for public access
  def upload_pdf_to_storage(pdf_path)
    blob = File.open(pdf_path, 'rb') do |file|
      ActiveStorage::Blob.create_and_upload!(
        io: file,
        filename: "cert_rejection_#{application.id}_#{Time.current.to_i}.pdf",
        content_type: 'application/pdf'
      )
    end

    Rails.logger.info "Uploaded fax PDF to ActiveStorage, blob ID: #{blob.id}"
    blob
  rescue StandardError => e
    Rails.logger.error "Failed to upload PDF to storage for Application ID: #{application.id} - #{e.message}"
    nil
  end

  # Generate public blob URL for Twilio
  def generate_blob_url(blob)
    host = default_url_options[:host]
    protocol = default_url_options[:protocol] || 'https'

    if host.blank?
      Rails.logger.error 'Host not configured for blob URLs - cannot generate fax media URL'
      return nil
    end

    Rails.application.routes.url_helpers.rails_blob_url(blob, host: host, protocol: protocol)
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
    failure_result(method: FAX_METHOD, error: e.message)
  rescue StandardError => e
    Rails.logger.error "Unexpected error sending fax for Application ID: #{application.id} - #{e.message}"
    failure_result(method: FAX_METHOD, error: e.message)
  end

  # Handle the result from fax service
  def handle_fax_result(fax_result)
    return failure_result(method: FAX_METHOD, error: 'Fax service returned no result') unless fax_result

    fax_sid = fax_result.sid
    Rails.logger.info "Fax successfully sent to medical provider for Application ID: #{application.id} - Fax SID: #{fax_sid}"
    { success: true, method: FAX_METHOD, fax_sid: fax_sid }
  end

  # Get fax sending options
  def fax_options
    {
      quality: 'fine',
      status_callback: fax_status_callback_url
    }.compact
  end

  def fax_status_callback_url
    host = default_url_options[:host]
    return nil if host.blank?

    Rails.application.routes.url_helpers.webhooks_twilio_fax_status_url(
      host: host,
      protocol: default_url_options[:protocol] || 'https'
    )
  end

  def default_url_options
    Rails.application.config.action_mailer.default_url_options || {}
  end

  # Clean up temporary PDF file
  def cleanup_temp_file(pdf_path)
    FileUtils.rm_f(pdf_path) if pdf_path && File.exist?(pdf_path)
  end

  def purge_blob(blob)
    blob.purge_later
  rescue StandardError => e
    Rails.logger.error "Failed to purge fax blob #{blob.id} for Application ID: #{application.id} - #{e.message}"
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
    Rails.root.join('tmp', "certification_rejection_#{application.id}_#{Time.current.to_i}.pdf")
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
    methods << DOCUMENT_SIGNING_METHOD if document_signing_preferred?
    methods << EMAIL_METHOD if email_available?
    methods << FAX_METHOD if fax_available?
    methods
  end
end
