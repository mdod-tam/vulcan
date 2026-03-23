# frozen_string_literal: true

class MedicalCertificationMailbox < ApplicationMailbox
  APPLICATION_ID_PATTERN = /\bApplication(?:\s+ID)?\s*[:#]?\s*(\d+)\b/i
  MAX_ATTACHMENT_SIZE = 10.megabytes
  ALLOWED_ATTACHMENT_TYPES = %w[application/pdf image/jpeg image/png image/gif].freeze

  before_processing :ensure_application
  before_processing :ensure_sender_authorized
  before_processing :ensure_valid_certification_request
  before_processing :validate_attachments

  def process
    create_audit_record

    mail.attachments.each do |attachment|
      attach_certification(attachment)
    end

    transition_application_to_received!

    notify_admin
    notify_constituent
  end

  private

  def create_audit_record
    record_audit_event('medical_certification_received',
                       sender_email: sender_email,
                       sender_verification: sender_verification)
  end

  def transition_application_to_received!
    previous_status = application.medical_certification_status || 'requested'

    application.update!(
      medical_certification_status: 'received',
      updated_at: Time.current
    )

    ApplicationStatusChange.create!(
      application: application,
      user: nil, # No admin user for auto-processing
      from_status: previous_status,
      to_status: 'received',
      metadata: {
        change_type: 'medical_certification',
        submission_method: 'email',
        received_at: Time.current.iso8601,
        inbound_email_id: inbound_email.id,
        sender_email: sender_email,
        sender_verification: sender_verification
      }
    )
  end

  def attach_certification(attachment)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(attachment.body.decoded),
      filename: attachment.filename,
      content_type: attachment.content_type
    )

    application.medical_certification.attach(blob)
  end

  def notify_admin
    record_audit_event('medical_certification_received_admin_notified',
                       sender_email: sender_email,
                       sender_verification: sender_verification)
  end

  def notify_constituent
    return if application&.user.blank?

    NotificationService.create_and_deliver!(
      type: 'medical_certification_received',
      recipient: application.user,
      actor: audit_actor,
      notifiable: application,
      metadata: {
        inbound_email_id: inbound_email.id,
        sender_email: sender_email,
        sender_verification: sender_verification,
        submission_method: 'email'
      },
      channel: :email,
      deliver: false
    )
  rescue StandardError => e
    Rails.logger.error("Failed to create constituent notification for medical certification email: #{e.message}")
  end

  def ensure_application
    return if application.present?

    bounce_with_notification(
      :application_not_found,
      'Unable to match this email to an application. Include the Application ID from the original request.'
    )
  end

  def ensure_sender_authorized
    return if application.blank?

    if provider_email.blank?
      bounce_with_notification(
        :provider_not_found,
        'No medical provider email is configured for this application.'
      )
      return
    end

    return if sender_matches_provider?
    return if sender_from_provider_domain?

    bounce_with_notification(
      :unauthorized_sender,
      'Sender email does not match the requesting medical provider. Please reply from the provider office domain or contact support.'
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
      return
    end

    mail.attachments.each do |attachment|
      validate_attachment!(attachment)
    rescue StandardError => e
      bounce_with_notification(
        :invalid_attachment,
        "Invalid attachment: #{e.message}"
      )
      break
    end
  end

  def validate_attachment!(attachment)
    raise 'File size exceeds 10MB limit' if attachment.body.decoded.size > MAX_ATTACHMENT_SIZE

    return if ALLOWED_ATTACHMENT_TYPES.include?(attachment.content_type)

    raise 'File type not allowed. Allowed types: PDF, JPEG, PNG, GIF'
  end

  def bounce_with_notification(error_type, message)
    record_audit_event("medical_certification_#{error_type}",
                       error: message,
                       sender_email: sender_email,
                       sender_verification: sender_verification)

    bounce_with medical_provider_submission_error_mail(error_type, message)
  rescue StandardError => e
    Rails.logger.error("Failed to send mailbox bounce notification: #{e.message}")
  end

  def medical_provider_submission_error_mail(error_type, message)
    MedicalProviderMailer.with(
      medical_provider: bounce_sender_contact,
      application: application,
      error_type: error_type,
      message: message
    ).certification_submission_error
  end

  def bounce_sender_contact
    Struct.new(:email).new(sender_email.presence || provider_email || 'unknown@example.com')
  end

  def sender_email
    @sender_email ||= mail.from&.first.to_s.downcase.strip
  end

  def provider_email
    application&.medical_provider_email.to_s.downcase.strip
  end

  def sender_matches_provider?
    sender_email.present? && provider_email.present? && sender_email == provider_email
  end

  def sender_from_provider_domain?
    sender_domain = email_domain(sender_email)
    provider_domain = email_domain(provider_email)
    return false if sender_domain.blank? || provider_domain.blank?

    sender_domain == provider_domain
  end

  def sender_verification
    return 'provider_exact' if sender_matches_provider?
    return 'provider_domain_delegate' if sender_from_provider_domain?

    'unverified'
  end

  def email_domain(email)
    return nil if email.blank?

    email.split('@').last
  end

  def record_audit_event(action, metadata = {})
    AuditEventService.log(
      actor: audit_actor,
      action: action,
      auditable: application,
      metadata: base_audit_metadata.merge(metadata)
    )
  end

  def base_audit_metadata
    {
      application_id: application&.id,
      inbound_email_id: inbound_email.id,
      email_subject: mail.subject,
      email_from: sender_email,
      submission_method: 'email'
    }
  end

  def audit_actor
    User.system_user
  end

  def application
    return @application if defined?(@application)

    application_id = extract_application_id_from_email
    @application = Application.find_by(id: application_id)
  end

  def extract_application_id_from_email
    subject_match = mail.subject.to_s.match(APPLICATION_ID_PATTERN)
    return subject_match[1] if subject_match

    body_match = mail.body.decoded.to_s.match(APPLICATION_ID_PATTERN)
    return body_match[1] if body_match

    extract_application_id_from_plus_address
  end

  def extract_application_id_from_plus_address
    plus_address = Array(mail.to).find { |to| to.to_s.include?('+') }
    return nil unless plus_address

    token = plus_address.to_s.split('@').first.split('+').last
    return token if token.match?(/^\d+$/)

    Application.find_signed(token, purpose: :medical_certification)&.id
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end
end
