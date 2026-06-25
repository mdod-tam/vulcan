# frozen_string_literal: true

class MedicalProviderMailer < ApplicationMailer
  include Rails.application.routes.url_helpers

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # Proxy methods for NotificationService compatibility
  # These delegate to the existing methods with proper parameter mapping

  def requested(notifiable, notification)
    # Map to request_certification method
    self.class.with(
      application: notifiable,
      timestamp: notification.metadata['timestamp'],
      notification_id: notification.id
    ).request_certification
  end

  def approved(notifiable, notification)
    # For now, delegate to a simple approval method
    # This can be expanded later if needed
    self.class.with(
      application: notifiable,
      notification: notification
    ).certification_approved
  end

  def rejected(notifiable, notification)
    # Map to certification_rejected method
    # Note: MedicalCertificationAttachmentService stores rejection data as 'reason'
    self.class.with(
      application: notifiable,
      rejection_reason: notification.metadata['reason'] ||
        notification.metadata['rejection_reason'] ||
        notifiable.medical_certification_rejection_reason ||
        'Not specified',
      admin: notification.actor,
      secure_upload_url: notification.metadata['secure_upload_url']
    ).certification_rejected
  end

  # New method for approved certifications
  def certification_approved
    locale = provider_email_locale
    template = find_text_template('medical_provider_certification_approved', locale: locale)
    variables = build_approval_variables
    log_debug_variables('certification_approved', variables)

    subject, body = template.render(**variables)
    log_rendered_output('certification_approved', subject, body)

    send_approval_email(subject, body)
  rescue StandardError => e
    log_certification_error('certification_approved', params[:application]&.medical_provider_email, e)
    raise e
  end

  # Notify a medical provider that a certification has been rejected.
  # Uses RejectionReason.resolve when a medical-certification ProofReview stores
  # rejection_reason_code, so body text is DB-stored and locale-aware.
  # @param application [Application] The application with the rejected certification
  # @param rejection_reason [String] Fallback reason text when no code is stored
  # @param admin [User] The admin who rejected the certification
  def certification_rejected
    locale = provider_email_locale
    template = find_text_template('medical_provider_certification_rejected', locale: locale)
    variables = build_rejection_variables(locale)
    log_debug_variables('certification_rejected', variables)

    subject, body = template.render(**variables)
    log_rendered_output('certification_rejected', subject, body)

    send_rejection_email(subject, body)
  rescue StandardError => e
    log_certification_error('certification_rejected', params[:application]&.medical_provider_email, e)
    raise e
  end

  # Request certification from a medical provider
  # @param application [Application] The application requiring certification
  # @param timestamp [String] ISO8601 timestamp of when the request was made
  # @param notification_id [Integer] ID of the notification record for tracking
  def request_certification
    locale = provider_email_locale
    template = find_text_template('medical_provider_request_certification', locale: locale)
    variables = build_request_certification_variables
    log_debug_variables('request_certification', variables)

    subject, body = template.render(**variables)
    log_rendered_output('request_certification', subject, body)

    send_request_certification_email(subject, body)
  rescue StandardError => e
    log_certification_error('request_certification', params[:application]&.medical_provider_email, e)
    raise e
  end

  private

  def build_approval_variables
    application = params[:application]
    constituent = application.user

    {
      constituent_full_name: constituent.full_name,
      application_id: application.id,
      support_email: Policy.get('support_email') || 'mat.program1@maryland.gov'
    }.compact
  end

  def build_rejection_variables(locale = 'en')
    application = params[:application]
    constituent = application.user
    rejection_reason = resolve_medical_cert_rejection_reason(application, locale)

    {
      constituent_full_name: constituent.full_name,
      application_id: application.id,
      rejection_reason: rejection_reason,
      secure_upload_url: params[:secure_upload_url].to_s,
      download_form_url: build_download_form_url,
      certification_resubmission_instructions: certification_resubmission_instructions(locale),
      support_email: Policy.get('support_email') || 'mat.program1@maryland.gov'
    }.compact
  end

  # Resolves rejection body from RejectionReason when code is stored on the latest
  # medical-certification ProofReview; otherwise uses passed-in text.
  def resolve_medical_cert_rejection_reason(application, locale)
    latest_review = application.latest_medical_rejection_review
    code = latest_review&.rejection_reason_code.presence
    fallback_reason = params[:rejection_reason] ||
                      latest_review&.rejection_reason ||
                      application.medical_certification_rejection_reason ||
                      'Not specified'

    return fallback_reason if code.blank?

    reason = RejectionReason.resolve(
      code: code,
      proof_type: 'medical_certification',
      locale: locale
    )
    reason&.body.presence || fallback_reason
  end

  # Locale for provider-facing emails based on the associated application user.
  def provider_email_locale
    resolve_template_locale(recipient: params[:application]&.user)
  end

  def build_request_certification_variables
    application = params[:application]
    timestamp = params[:timestamp]
    constituent = application.user

    {
      constituent_full_name: constituent.full_name,
      request_count_message: format_request_count_message(application),
      timestamp_formatted: format_request_timestamp(timestamp),
      constituent_dob_formatted: format_constituent_dob(constituent),
      constituent_phone_formatted: format_constituent_phone(constituent),
      constituent_email: format_constituent_email(constituent),
      constituent_address_formatted: format_constituent_address(constituent),
      application_id: application.id,
      download_form_url: build_download_form_url,
      secure_upload_url: params[:secure_upload_url].to_s,
      certification_submission_instructions: certification_submission_instructions,
      support_email: Policy.get('support_email') || 'mat.program1@maryland.gov'
    }.compact
  end

  def certification_submission_instructions
    certification_instructions(
      'medical_provider_mailer.certification_submission_instructions',
      locale: provider_email_locale
    )
  end

  def certification_resubmission_instructions(locale)
    certification_instructions(
      'medical_provider_mailer.certification_resubmission_instructions',
      locale: locale
    )
  end

  def certification_instructions(scope, locale:)
    delivery_method = params[:secure_upload_url].present? ? 'secure' : 'fax'

    I18n.t(
      "#{scope}.#{delivery_method}",
      locale: locale,
      download_form_url: build_download_form_url,
      secure_upload_url: params[:secure_upload_url],
      support_email: support_email
    ).strip
  end

  def format_request_count_message(application)
    request_count = application.medical_certification_request_count || 1
    request_count > 1 ? "This is a follow-up request (Request ##{request_count})" : ''
  end

  def format_request_timestamp(timestamp)
    time = timestamp ? Time.iso8601(timestamp) : Time.current
    time.strftime('%B %d, %Y at %I:%M %p %Z')
  end

  def format_constituent_dob(constituent)
    constituent.date_of_birth&.strftime('%m/%d/%Y') || 'Not Provided'
  end

  def format_constituent_phone(constituent)
    constituent.phone.presence || 'Not Provided'
  end

  def format_constituent_email(constituent)
    constituent.email.presence || 'Not Provided'
  end

  def format_constituent_address(constituent)
    [
      constituent.physical_address_1,
      constituent.physical_address_2,
      "#{constituent.city}, #{constituent.state} #{constituent.zip_code}"
    ].compact_blank.join("\n")
  end

  def build_download_form_url
    medical_certification_form_url(host: default_url_options[:host])
  rescue StandardError
    '#'
  end

  def send_approval_email(subject, body)
    application = params[:application]

    mail_with_text_body(
      {
        to: application.medical_provider_email,
        from: 'no_reply@mdmat.org',
        reply_to: support_email,
        subject: subject,
        message_stream: 'outbound'
      },
      body.to_s
    )
  end

  def send_rejection_email(subject, body)
    application = params[:application]

    mail_with_text_body(
      {
        to: application.medical_provider_email,
        from: 'no_reply@mdmat.org',
        reply_to: support_email,
        subject: subject,
        message_stream: 'outbound'
      },
      body.to_s
    )
  end

  def send_request_certification_email(subject, body)
    application = params[:application]
    notification_id = params[:notification_id]

    mail_options = build_request_mail_options(application, subject)
    add_notification_tracking(mail_options, notification_id)

    mail_with_text_body(mail_options, body.to_s)
  end

  def build_request_mail_options(application, subject)
    {
      to: application.medical_provider_email,
      from: 'no_reply@mdmat.org',
      reply_to: support_email,
      subject: subject,
      message_stream: 'outbound'
    }
  end

  def add_notification_tracking(mail_options, notification_id)
    return if notification_id.blank?

    notification = Notification.find_by(id: notification_id)
    mail_options[:message_id] = notification.message_id if notification&.message_id.present?
  end

  def log_debug_variables(context, variables)
    Rails.logger.debug { "DEBUG: #{context} - Variables: #{sanitized_mail_variables(variables).inspect}" } unless Rails.env.production?
  end

  def log_rendered_output(context, subject, body)
    Rails.logger.debug { "DEBUG: #{context} - Rendered Subject: #{subject.inspect}" } unless Rails.env.production?
    Rails.logger.debug { "DEBUG: #{context} - Rendered Body: [REDACTED_SECURE_LINK_BODY]" } if log_body_redacted?(body)
    Rails.logger.debug { "DEBUG: #{context} - Rendered Body: #{body.inspect}" } if log_body_plain?(body)
  end

  def sanitized_mail_variables(variables)
    redact_sensitive_mail_value(variables.to_h.deep_dup)
  end

  def redact_sensitive_mail_value(value, key = nil)
    sanitize_secure_value(value, key)
  end

  def log_body_redacted?(body)
    !Rails.env.production? && body.to_s.match?(%r{https?://\S+})
  end

  def log_body_plain?(body)
    !Rails.env.production? && !log_body_redacted?(body)
  end

  def support_email
    Policy.get('support_email') || 'mat.program1@maryland.gov'
  end

  def log_certification_error(context, recipient, error)
    Rails.logger.error("Failed to send #{context} email to #{recipient}: #{sanitize_secure_error_message(error.message)}")
    Rails.logger.error(sanitize_secure_error_message(error.backtrace&.join("\n")))
  end
end
