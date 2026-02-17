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
    self.class.with(
      application: notifiable,
      rejection_reason: notification.metadata['reason'] || 'Not specified',
      admin: notification.actor
    ).certification_rejected
  end

  # New method for approved certifications
  def certification_approved
    template = load_email_template('medical_provider_certification_approved')
    variables = build_approval_variables
    log_debug_variables('certification_approved', variables)

    subject, body = template.render(**variables)
    log_rendered_output('certification_approved', subject, body)

    send_approval_email(subject, body)
  rescue StandardError => e
    log_certification_error('certification_approved', params[:application]&.medical_provider_email, e)
    raise e
  end

  # Notify a medical provider that a certification has been rejected
  # @param application [Application] The application with the rejected certification
  # @param rejection_reason [String] The reason for rejection
  # @param admin [User] The admin who rejected the certification
  def certification_rejected
    template = load_email_template('medical_provider_certification_rejected')
    variables = build_rejection_variables
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
    template = load_email_template('medical_provider_request_certification')
    variables = build_request_certification_variables
    log_debug_variables('request_certification', variables)

    subject, body = template.render(**variables)
    log_rendered_output('request_certification', subject, body)

    send_request_certification_email(subject, body)
  rescue StandardError => e
    log_certification_error('request_certification', params[:application]&.medical_provider_email, e)
    raise e
  end

  # Notify a medical provider about an error during certification submission
  # @param medical_provider [User] The medical provider who sent the email
  # @param application [Application, nil] The associated application, if found
  # @param error_type [Symbol] The type of error (:provider_not_found, :invalid_certification_request, etc.)
  # @param message [String] The error message
  def certification_submission_error
    medical_provider, application, message = extract_submission_error_params
    process_submission_error_email(medical_provider, application, message)
  rescue StandardError => e
    log_certification_error('certification_submission_error', params[:medical_provider]&.email, e)
    raise e
  end

  private

  def load_email_template(template_name)
    EmailTemplate.find_by!(name: template_name, format: :text)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email template (text format) not found for #{template_name}"
  end

  def build_submission_error_variables(medical_provider, application, message)
    {
      medical_provider_email: medical_provider.email,
      error_message: message,
      constituent_full_name: application&.user&.full_name,
      application_id: application&.id
    }.compact
  end

  def build_approval_variables
    application = params[:application]
    constituent = application.user

    {
      constituent_full_name: constituent.full_name,
      application_id: application.id
    }.compact
  end

  def build_rejection_variables
    application = params[:application]
    rejection_reason = params[:rejection_reason]
    constituent = application.user
    remaining_attempts = 8 - application.total_rejections

    {
      constituent_full_name: constituent.full_name,
      application_id: application.id,
      rejection_reason: rejection_reason,
      remaining_attempts: remaining_attempts
    }.compact
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
      constituent_address_formatted: format_constituent_address(constituent),
      application_id: application.id,
      download_form_url: build_download_form_url(application)
    }.compact
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

  def format_constituent_address(constituent)
    [
      constituent.physical_address_1,
      constituent.physical_address_2,
      "#{constituent.city}, #{constituent.state} #{constituent.zip_code}"
    ].compact_blank.join("\n")
  end

  def build_download_form_url(application)
    medical_certification_form_url(
      application.signed_id(purpose: :medical_certification),
      host: default_url_options[:host]
    )
  rescue StandardError
    '#'
  end

  def send_approval_email(subject, body)
    application = params[:application]

    mail(
      to: application.medical_provider_email,
      from: 'info@mdmat.org',
      reply_to: 'medical-certification@maryland.gov',
      subject: subject,
      message_stream: 'outbound'
    ) do |format|
      format.text { render plain: body.to_s }
    end
  end

  def send_rejection_email(subject, body)
    application = params[:application]

    mail(
      to: application.medical_provider_email,
      from: 'info@mdmat.org',
      reply_to: 'medical-certification@maryland.gov',
      subject: subject,
      message_stream: 'outbound'
    ) do |format|
      format.text { render plain: body.to_s }
    end
  end

  def send_request_certification_email(subject, body)
    application = params[:application]
    notification_id = params[:notification_id]

    mail_options = build_request_mail_options(application, subject)
    add_notification_tracking(mail_options, notification_id)

    mail(mail_options) do |format|
      format.text { render plain: body.to_s }
    end
  end

  def build_request_mail_options(application, subject)
    {
      to: application.medical_provider_email,
      from: 'info@mdmat.org',
      reply_to: 'medical-certification@maryland.gov',
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
    Rails.logger.debug { "DEBUG: #{context} - Variables: #{variables.inspect}" } unless Rails.env.production?
  end

  def log_rendered_output(context, subject, body)
    Rails.logger.debug { "DEBUG: #{context} - Rendered Subject: #{subject.inspect}" } unless Rails.env.production?
    Rails.logger.debug { "DEBUG: #{context} - Rendered Body: #{body.inspect}" } unless Rails.env.production?
  end

  def send_submission_error_email(medical_provider, subject, body)
    mail(
      to: medical_provider.email,
      from: 'info@mdmat.org',
      reply_to: 'medical-certification@maryland.gov',
      subject: subject,
      message_stream: 'outbound'
    ) do |format|
      format.text { render plain: body.to_s }
    end
  end

  def log_certification_error(context, recipient, error)
    Rails.logger.error("Failed to send #{context} email to #{recipient}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))
  end

  def extract_submission_error_params
    [
      params[:medical_provider],
      params[:application],
      params[:message]
    ]
  end

  def process_submission_error_email(medical_provider, application, message)
    template = load_email_template('medical_provider_certification_submission_error')
    variables = build_submission_error_variables(medical_provider, application, message)
    log_debug_variables('certification_submission_error', variables)

    subject, body = template.render(**variables)
    log_rendered_output('certification_submission_error', subject, body)

    send_submission_error_email(medical_provider, subject, body)
  end
end
