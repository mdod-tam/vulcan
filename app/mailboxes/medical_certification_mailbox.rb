# frozen_string_literal: true

class MedicalCertificationMailbox < ApplicationMailbox
  before_processing :ensure_medical_provider
  before_processing :ensure_valid_certification_request
  before_processing :validate_attachments

  def process
    # Application has a single medical_certification attachment, so we treat the
    # first valid attachment as the canonical submission for this email.
    attachment = mail.attachments.first

    MedicalCertificationAttachmentService.attach_certification(
      application: application,
      blob_or_file: build_blob_from_attachment(attachment),
      status: :received,
      admin: User.system_user,
      submission_method: :email,
      metadata: certification_metadata
    )

    AuditEventService.log(
      actor: User.system_user,
      action: 'medical_certification_received',
      auditable: application,
      metadata: certification_metadata
    )
  end

  private

  def ensure_medical_provider
    return if medical_provider

    bounce_with_notification(
      :provider_not_found,
      'Email sender not recognized as a registered medical provider'
    )
  end

  def ensure_valid_certification_request
    return if application&.medical_certification_requested?

    bounce_with_notification(
      :invalid_certification_request,
      'No pending certification request found for this provider'
    )
  end

  def validate_attachments
    if mail.attachments.empty?
      bounce_with_notification(
        :no_attachments,
        'No attachments found in email'
      )
    end

    mail.attachments.each do |attachment|
      validate_attachment(attachment)
    rescue StandardError => e
      bounce_with_notification(
        :invalid_attachment,
        "Invalid attachment: #{e.message}"
      )
    end
  end

  def validate_attachment(attachment)
    # Check file size
    raise 'File size exceeds 10MB limit' if attachment.body.decoded.size > 10.megabytes

    # Check file type
    allowed_types = %w[application/pdf image/jpeg image/png image/gif]
    return if allowed_types.include?(attachment.content_type)

    raise 'File type not allowed. Allowed types: PDF, JPEG, PNG, GIF'
  end

  def bounce_with_notification(error_type, message)
    # Use System User if constituent isn't available (e.g., bounced before application lookup)
    event_user = application&.user || User.system_user
    AuditEventService.log(
      actor: event_user,
      action: "medical_certification_#{error_type}",
      auditable: application,
      metadata: {
        application_id: application&.id,
        medical_provider_id: medical_provider&.id,
        error: message,
        inbound_email_id: inbound_email.id
      }
    )

    if defined?(MedicalProviderMailer.certification_submission_error)
      bounce_with MedicalProviderMailer.certification_submission_error(
        medical_provider,
        application,
        error_type,
        message
      )
    else
      # If the mailer method doesn't exist, just bounce with a simple message
      bounce_with message
    end
  end

  def medical_provider
    return @medical_provider if defined?(@medical_provider)

    @medical_provider = MedicalProvider.find_by_email(mail.from.first)
  end

  def application
    # Extract application ID from the email subject or body
    # This assumes you include an application ID in the original request email
    application_id = extract_application_id_from_email
    if defined?(@application)
      @application
    else
      @application = Application.find_by(id: application_id)
    end
  end

  def extract_application_id_from_email
    # Look for application ID in subject (e.g., "Medical Certification for Application #123")
    subject_match = mail.subject.match(/Application #?(\d+)/i)
    return subject_match[1] if subject_match

    # Look for application ID in email body
    body_match = mail.body.decoded.match(/Application #?(\d+)/i)
    return body_match[1] if body_match

    # If we can't find an ID, check if this is a reply to a specific request
    # This assumes you're using a mailbox hash with the application ID
    if mail.to.any? { |to| to.include?('+') }
      mailbox_hash = mail.to.find { |to| to.include?('+') }.split('@').first.split('+').last
      return mailbox_hash if mailbox_hash.match?(/^\d+$/)
    end

    nil
  end

  def build_blob_from_attachment(attachment)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(attachment.body.decoded),
      filename: attachment.filename,
      content_type: attachment.content_type
    )
  end

  def certification_metadata
    {
      application_id: application.id,
      medical_provider_id: medical_provider.id,
      inbound_email_id: inbound_email.id,
      email_subject: mail.subject,
      email_from: mail.from.first,
      submission_method: 'email'
    }
  end
end
