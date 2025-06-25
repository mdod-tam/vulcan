# frozen_string_literal: true

# ProofSubmissionMailbox processes inbound emails containing proof documents
#
# PROCESSING FLOW:
# 1. Email arrives and is routed here by ApplicationMailbox
# 2. BEFORE_PROCESSING CALLBACKS run in order (ANY can bounce the email):
#    - ensure_constituent: Bounces if sender email not found in users table
#    - ensure_active_application: Bounces if no active application found
#    - check_rate_limit: Bounces if rate limit exceeded
#    - check_max_rejections: Bounces if max rejection limit reached
#    - validate_attachments: Bounces if no attachments or invalid attachments
# 3. If ALL callbacks pass, process() method runs to attach proofs
# 4. If ANY callback fails, bounce_with_notification() is called which:
#    - Creates audit event
#    - Sends error email to sender
#    - Marks inbound_email as 'bounced'
#    - Throws :bounce to halt processing
#
# TESTING NOTES:
# - Tests must stub ALL before_processing callbacks or provide valid test data
# - A bounced email will never reach the process() method
# - Check inbound_email.status to see if email was bounced vs processed

class ProofSubmissionMailbox < ApplicationMailbox
  # CRITICAL: These callbacks run BEFORE process() and can bounce the email
  # If ANY callback calls bounce_with_notification(), processing stops immediately
  before_processing :ensure_constituent        # Bounces if sender not found
  before_processing :ensure_active_application # Bounces if no active app
  before_processing :check_rate_limit          # Bounces if rate limited
  before_processing :check_max_rejections      # Bounces if max rejections hit
  before_processing :validate_attachments      # Bounces if no/invalid attachments

  def process
    # NOTE: This method only runs if ALL before_processing callbacks pass
    Rails.logger.info "PROOF SUBMISSION MAILBOX PROCESSING: Email from #{mail.from&.first} with subject '#{mail.subject}'"

    # Create an audit record for the submission
    create_audit_record

    # Process each attachment
    mail.attachments.each do |attachment|
      # Determine proof type based on email subject or content
      proof_type = determine_proof_type(mail.subject, mail.body.decoded)

      # Attach the file to the application's proof
      attach_proof(attachment, proof_type)
    end

    # Notify admin of new proof submission
    notify_admin

    Rails.logger.info 'PROOF SUBMISSION MAILBOX COMPLETE: Successfully processed email'
  end

  private

  def create_audit_record
    Event.create!(
      user: constituent,
      action: 'proof_submission_received',
      metadata: {
        application_id: application.id,
        inbound_email_id: inbound_email.id,
        email_subject: mail.subject,
        email_from: mail.from.first
      }
    )
  end

  def determine_proof_type(subject, body)
    text = [subject, body].join(' ').to_s.downcase

    # Check for medical certification keywords
    if text.match?(/\b(medical|certification|doctor|provider|health)\b/) ||
       mail.to.to_s.downcase.include?('medical-cert')
      :medical_certification
    # Check for residency proof keywords
    elsif text.match?(/\b(residency|address)\b/) && !text.match?(/\bincome\b/)
      :residency
    # Default to income proof
    else
      :income
    end
  end

  def attach_proof(attachment, proof_type)
    # Create a blob from the attachment
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(attachment.body.decoded),
      filename: attachment.filename,
      content_type: attachment.content_type
    )

    # Use the ProofAttachmentService to consistently handle attachments
    result = ProofAttachmentService.attach_proof({
                                                   application: application,
                                                   proof_type: proof_type,
                                                   blob_or_file: blob,
                                                   status: :not_reviewed,
                                                   admin: nil,
                                                   submission_method: :email,
                                                   metadata: {
                                                     ip_address: '0.0.0.0',
                                                     email_subject: mail.subject,
                                                     email_from: mail.from.first,
                                                     inbound_email_id: inbound_email.id
                                                   }
                                                 })

    if result[:success]
      # ProofAttachmentService already handled the attachment, audit events, and notifications
      # No need to attach again - just return successfully
      return
    end

    Rails.logger.error "Failed to attach proof via email: #{result[:error]&.message}"
    raise "Failed to attach proof: #{result[:error]&.message}"
  end

  def notify_admin
    # Notify admin of new proof submission
    Event.create!(
      user: constituent,
      action: 'proof_submission_processed',
      metadata: {
        application_id: application.id,
        inbound_email_id: inbound_email.id
      }
    )
  end

  def ensure_constituent
    return if constituent

    bounce_with_notification(
      :constituent_not_found,
      'Email sender not recognized as a constituent'
    )
  end

  def ensure_active_application
    # An application is considered active for proof submission if its status
    # is one of: in_progress, needs_information, reminder_sent, or awaiting_documents.
    # This aligns with the :active scope defined in ApplicationStatusManagement.
    active_statuses = %i[in_progress needs_information reminder_sent awaiting_documents]
    return if application && active_statuses.include?(application.status&.to_sym)

    bounce_with_notification(
      :inactive_application,
      'No active application found for this constituent'
    )
  end

  def check_rate_limit
    RateLimit.check!(:proof_submission, constituent.id, :email)
  rescue RateLimit::ExceededError
    bounce_with_notification(
      :rate_limit_exceeded,
      'You have exceeded the maximum number of proof submissions allowed per hour'
    )
  end

  def check_max_rejections
    # IMPORTANT: This Policy.get() call hits the database - ensure 'max_proof_rejections' exists in seeds.rb
    # If this returns nil, the bounce logic will not work as expected
    # Debug: Check Policy.find_by(key: 'max_proof_rejections') in rails console
    max_rejections = Policy.get('max_proof_rejections')
    return unless max_rejections.present? && application.total_rejections.present?
    return unless application.total_rejections >= max_rejections

    bounce_with_notification(
      :max_rejections_reached,
      'Maximum number of proof submission attempts reached'
    )
  end

  def validate_attachments
    # Check if attachments are present *before* iterating
    if mail.attachments.blank?
      bounce_with_notification(
        :no_attachments,
        'No attachments found in email'
      )
      return # Ensure we stop processing if bounced
    end

    # Iterate and validate each attachment
    mail.attachments.each do |attachment|
      ProofAttachmentValidator.validate!(attachment)
    rescue ProofAttachmentValidator::ValidationError => e
      bounce_with_notification(
        :invalid_attachment,
        "Invalid attachment: #{e.message}"
      )
      break # Stop processing on first invalid attachment
    end
  end

  def bounce_with_notification(error_type, message)
    # BOUNCE PROCESSING: This method halts all email processing
    Rails.logger.info "MAILBOX BOUNCE: #{error_type} - #{message} (from: #{mail.from&.first}, inbound_email: #{inbound_email.id})"

    # Record the bounce event with detailed context
    # IMPORTANT: Handle transaction/race condition issues with system_user creation
    # In test environments, User.system_user might be created in a different transaction
    # context, leading to foreign key constraint violations when creating Events
    # This robust approach ensures we always have a valid user for event creation
    event_user = constituent
    if event_user.nil?
      begin
        event_user = User.system_user
        # Double-check the user exists and is persisted
        event_user.reload if event_user.persisted?
      rescue ActiveRecord::RecordNotFound => e
        Rails.logger.warn "System user not found during bounce: #{e.message}. Creating new system user."
        # Clear the memoized value and try again
        User.instance_variable_set(:@system_user, nil)
        event_user = User.system_user
      end
    end

    Event.create!(
      user: event_user,
      action: "proof_submission_#{error_type}",
      metadata: {
        application_id: application&.id,
        error: message,
        error_type: error_type,
        inbound_email_id: inbound_email.id,
        sender_email: mail.from&.first,
        email_subject: mail.subject,
        bounce_timestamp: Time.current.iso8601
      }
    )

    # Send error notification to sender with clear explanation
    bounce_mail = ApplicationNotificationsMailer.proof_submission_error(
      constituent,
      application,
      error_type,
      "Email processing failed: #{message}"
    )
    bounce_mail.deliver_now

    # Mark inbound email as bounced for tracking
    inbound_email.update!(status: 'bounced')

    Rails.logger.info "MAILBOX BOUNCE COMPLETE: Email #{inbound_email.id} marked as bounced, notification sent"

    # Halt all further processing - this prevents process() from running
    throw :bounce
  end

  def constituent
    return @constituent if defined?(@constituent)

    # Guard against nil mail.from or empty array
    from_email = mail.from&.first

    # Try to find the user by email first
    @constituent = from_email.present? ? User.find_by(email: from_email) : nil

    # If we can't find a constituent but can find an application via app_id_from_subject
    # and the from_email matches a provider's email in the app metadata, use the application's user
    @constituent = app_from_provider_email.user if @constituent.nil? && from_email.present? && app_from_provider_email.present?

    @constituent
  end

  def application
    return @application if defined?(@application)

    # If we found a constituent, use their most recent application
    @application = constituent.applications.order(created_at: :desc).first if constituent

    # If we still don't have an application but have a provider email, use the app found by that
    @application ||= app_from_provider_email

    @application
  end

  # Find an application linked to a medical provider's email (if any)
  def app_from_provider_email
    return @app_from_provider_email if defined?(@app_from_provider_email)

    from_email = mail.from&.first
    app_id = app_id_from_subject

    @app_from_provider_email = nil

    # Try to find the application by ID first if we have one
    if app_id.present?
      app = Application.find_by(id: app_id)

      # Check if the app's provider_email field matches this email
      @app_from_provider_email = app if app && app.medical_provider_email == from_email
    end

    # If we still don't have an application but have the provider's email, search by that
    if @app_from_provider_email.nil? && from_email.present?
      # Find the most recent application with this provider email
      @app_from_provider_email = Application.where(medical_provider_email: from_email)
                                            .order(created_at: :desc)
                                            .first
    end

    @app_from_provider_email
  end

  # Extract application ID from the subject line, if present
  def app_id_from_subject
    return nil if mail.subject.blank?

    # Match patterns like "Application #12345" or "App ID: 12345"
    match = mail.subject.match(/#(\d+)|\bID:?\s*(\d+)/)
    match[1] || match[2] if match
  end
end
