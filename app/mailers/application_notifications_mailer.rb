# frozen_string_literal: true

class ApplicationNotificationsMailer < ApplicationMailer
  layout false
  include Rails.application.routes.url_helpers
  include Mailers::ApplicationNotificationsHelper
  include Mailers::SharedPartialHelpers # Include the shared helpers

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  def application_submitted(application)
    @application = application
    @user = application.user

    # Set up mail options with CC for alternate contact if provided
    mail_options = {
      to: @user.effective_email,
      subject: 'Your Application Has Been Submitted',
      message_stream: 'notifications'
    }

    # Add CC for alternate contact if email is provided
    mail_options[:cc] = @application.alternate_contact_email if @application.alternate_contact_email.present?

    mail(mail_options)
  end

  # A helper method that handles common logging, instance variable setup,
  # subject formatting, and mail object creation.

  # extra_setup: an optional lambda to run any extra setup (e.g. setting
  #   @remaining_attempts and @reapply_date) before sending the email.

  def proof_approved(application, proof_review)
    handle_proof_approved_letter(application, proof_review)

    template_name = 'application_notifications_proof_approved'
    text_template = find_email_template(template_name)

    variables = build_proof_approved_variables(application, proof_review)

    send_email(application.user.effective_email, text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send proof approval email for application #{application&.id}, proof_review #{proof_review&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  def proof_rejected(application, proof_review)
    # Calculate rejection info
    remaining_attempts = 8 - application.total_rejections
    reapply_date = 3.years.from_now.to_date

    handle_proof_rejected_letter(application, proof_review, remaining_attempts, reapply_date)

    template_name = 'application_notifications_proof_rejected'
    text_template = find_email_template(template_name)

    variables = build_proof_rejected_variables(application, proof_review, remaining_attempts, reapply_date)

    send_proof_rejected_email(application.user, text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send proof rejection email for application #{application&.id}, proof_review #{proof_review&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  def max_rejections_reached(application)
    Rails.logger.info "Preparing max_rejections_reached email for Application ID: #{application.id}"
    Rails.logger.info "Delivery method: #{ActionMailer::Base.delivery_method}"

    reapply_date = 3.years.from_now.to_date
    handle_max_rejections_letter(application, reapply_date)

    template_name = 'application_notifications_max_rejections_reached'
    text_template = find_email_template(template_name)

    variables = build_max_rejections_variables(application, reapply_date)

    send_email(application.user.effective_email, text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send max rejections email for application #{application&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e if Rails.env.test? # Re-raise in test environment
  end

  def proof_needs_review_reminder(admin, applications)
    stale_reviews = filter_stale_reviews(applications)

    return handle_no_stale_reviews if stale_reviews.empty? && !Rails.env.test?

    template_name = 'application_notifications_proof_needs_review_reminder'
    text_template = find_email_template(template_name)

    variables = build_review_reminder_variables(admin, stale_reviews)

    send_email(admin.email, text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send review reminder email to admin #{admin&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e if Rails.env.test? # Re-raise in test environment
  end

  # Private helper methods for rendering partials are in Mailers::SharedPartialHelpers

  helper Mailers::ApplicationNotificationsHelper

  def account_created(constituent, temp_password)
    return handle_nil_constituent if constituent.nil?

    handle_account_created_letter(constituent, temp_password)

    template_name = 'application_notifications_account_created'
    text_template = find_email_template(template_name)

    variables = build_account_created_variables(constituent, temp_password)
    recipient_email = extract_recipient_email(constituent)

    send_email(recipient_email, text_template, variables)
  rescue StandardError => e
    Rails.logger.error("Failed to send account created email for #{constituent&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e # Re-raise to ensure job failures are tracked
  end

  def income_threshold_exceeded(constituent_params, notification_params)
    service_result = get_income_threshold_data(constituent_params, notification_params)

    template_name = 'application_notifications_income_threshold_exceeded'
    text_template = find_email_template(template_name)

    variables = build_income_threshold_variables(service_result)

    send_email(service_result[:constituent][:email], text_template, variables)
  rescue StandardError => e
    constituent_id = constituent_params.is_a?(Hash) ? constituent_params[:id] : constituent_params&.id
    Rails.logger.error("Failed to send income threshold exceeded email for constituent #{constituent_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  def proof_submission_error(constituent, application, _error_type, message)
    recipient_info = determine_proof_error_recipient(constituent, message)
    handle_proof_error_letter(constituent, application, message)

    template_name = 'application_notifications_proof_submission_error'
    text_template = find_email_template(template_name)

    variables = build_proof_error_variables(recipient_info[:full_name], message)

    send_email(recipient_info[:email], text_template, variables)
  rescue StandardError => e
    constituent_id = constituent&.id || 'unknown'
    application_id = application&.id || 'unknown'
    Rails.logger.error("Failed to send proof submission error email for constituent #{constituent_id}, application #{application_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  def registration_confirmation(user)
    active_vendors_text_list = build_active_vendors_list
    handle_registration_letter(user, active_vendors_text_list)

    template_name = 'application_notifications_registration_confirmation'
    text_template = find_email_template(template_name)

    variables = build_registration_variables(user, active_vendors_text_list)
    rendered_subject, rendered_text_body = text_template.render(**variables)

    message = mail(
      to: user.effective_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    ) do |format|
      format.text { render plain: rendered_text_body }
    end

    message.subject = rendered_subject if Rails.env.test?
    Rails.logger.debug { "[Registration Mailer] Rendered subject: #{rendered_subject.inspect}" }
    message
  rescue StandardError => e
    Rails.logger.error("Failed to send registration confirmation email for user #{user&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  def proof_received(application, proof_type)
    template_name = 'application_notifications_proof_approved'
    text_template = find_email_template(template_name)

    variables = build_proof_received_variables(application, proof_type)
    rendered_subject, rendered_text_body = text_template.render(**variables)

    # Customize the subject to be more appropriate for "received" vs "approved"
    rendered_subject = rendered_subject.gsub(/approved/i, 'received').gsub(/Approved/i, 'Received')

    mail(
      to: application.user.effective_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    ) do |format|
      format.text { render plain: rendered_text_body }
    end
  rescue StandardError => e
    Rails.logger.error("Failed to send proof received email for application #{application&.id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise e
  end

  private

  # Common letter generation helper
  def generate_letter_if_preferred(recipient, template_name, variables)
    return unless recipient.respond_to?(:communication_preference) && recipient.communication_preference == 'letter'

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: recipient,
      variables: variables
    ).queue_for_printing
  end

  # Common email template finder
  def find_email_template(template_name)
    EmailTemplate.find_by!(name: template_name, format: :text)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email templates not found for #{template_name}"
  end

  # Common base variables builder
  def build_base_email_variables(header_title, organization_name = nil)
    org_name = organization_name || Policy.get('organization_name') || 'Maryland Accessible Telecommunications'
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    header_logo_url = safe_asset_path('logo.png')

    {
      header_text: header_text(title: header_title, logo_url: header_logo_url),
      footer_text: footer_text(
        contact_email: footer_contact_email,
        website_url: footer_website_url,
        organization_name: org_name,
        show_automated_message: footer_show_automated_message
      ),
      header_logo_url: header_logo_url,
      header_subtitle: nil
    }
  end

  # Common email sender
  def send_email(recipient_email, template, variables, mail_options = {})
    rendered_subject, rendered_text_body = template.render(**variables)

    default_options = {
      to: recipient_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    }

    mail(default_options.merge(mail_options)) do |format|
      format.text { render plain: rendered_text_body }
    end
  end

  def safe_asset_path(asset_name)
    ActionController::Base.helpers.asset_path(asset_name, host: default_url_options[:host])
  rescue StandardError
    nil
  end

  # Proof rejected specific methods
  def handle_proof_rejected_letter(application, proof_review, remaining_attempts, reapply_date)
    return unless application.user.communication_preference == 'letter'

    generate_letter_if_preferred(
      application.user,
      'application_notifications_proof_rejected',
      {
        proof_type: proof_review.proof_type,
        proof_type_formatted: format_proof_type(proof_review.proof_type),
        rejection_reason: proof_review.rejection_reason || 'Documentation did not meet requirements',
        notes: proof_review.notes || '',
        remaining_attempts: remaining_attempts,
        reapply_date: reapply_date.strftime('%B %d, %Y'),
        first_name: application.user.first_name,
        last_name: application.user.last_name,
        application_id: application.id
      }
    )
  end

  def build_proof_rejected_variables(application, proof_review, remaining_attempts, reapply_date)
    user = application.user
    proof_type_formatted = format_proof_type(proof_review.proof_type)
    header_title = "Document Review Update: #{proof_type_formatted.capitalize} Needs Revision"

    base_variables = build_base_email_variables(header_title, 'MAT Program')
    proof_variables = {
      user_first_name: user.first_name,
      organization_name: 'MAT Program',
      proof_type_formatted: proof_type_formatted,
      rejection_reason: proof_review.rejection_reason,
      additional_instructions: proof_review.notes,
      sign_in_url: sign_in_url(host: default_url_options[:host])
    }
    conditional_variables = build_proof_rejected_conditional_variables(remaining_attempts, reapply_date)

    base_variables.merge(proof_variables).merge(conditional_variables).compact
  end

  def build_proof_rejected_conditional_variables(remaining_attempts, reapply_date)
    sign_in_url_value = sign_in_url(host: default_url_options[:host])

    if remaining_attempts.positive?
      {
        remaining_attempts_message_text: build_remaining_attempts_message(remaining_attempts, reapply_date),
        default_options_text: build_default_options_text(sign_in_url_value),
        archived_message_text: nil
      }
    else
      {
        remaining_attempts_message_text: nil,
        default_options_text: nil,
        archived_message_text: build_archived_message(reapply_date)
      }
    end
  end

  def build_remaining_attempts_message(remaining_attempts, reapply_date)
    "You have #{remaining_attempts} #{'attempt'.pluralize(remaining_attempts)} remaining to
    submit the required documentation before #{reapply_date.strftime('%B %d, %Y')}."
  end

  def build_default_options_text(sign_in_url_value)
    "Please sign in to your account at #{sign_in_url_value} to upload the corrected documents or reply to this email with the documents attached."
  end

  def build_archived_message(reapply_date)
    "Unfortunately, you have reached the maximum number of submission attempts. Your application has been archived.
    You may reapply after #{reapply_date.strftime('%B %d, %Y')}."
  end

  def send_proof_rejected_email(user, text_template, variables)
    send_email(
      user.email,
      text_template,
      variables,
      reply_to: ["proof@#{default_url_options[:host]}"]
    )
  end

  # Proof approved specific methods
  def handle_proof_approved_letter(application, proof_review)
    all_proofs_approved = application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?

    generate_letter_if_preferred(
      application.user,
      'application_notifications_proof_approved',
      {
        proof_type: proof_review.proof_type,
        proof_type_formatted: format_proof_type(proof_review.proof_type),
        all_proofs_approved: all_proofs_approved,
        first_name: application.user.first_name,
        last_name: application.user.last_name,
        application_id: application.id
      }
    )
  end

  def build_proof_approved_variables(application, proof_review)
    user = application.user
    proof_type_formatted = format_proof_type(proof_review.proof_type)
    all_proofs_approved = application.respond_to?(:all_proofs_approved?) && application.all_proofs_approved?
    header_title = "Document Review Update: #{proof_type_formatted.capitalize} Approved"

    base_variables = build_base_email_variables(header_title, 'MAT Program')
    proof_variables = {
      user_first_name: user.first_name,
      organization_name: 'MAT Program',
      proof_type_formatted: proof_type_formatted,
      all_proofs_approved_message_text: all_proofs_approved ? 'All required documents for your application have now been approved.' : nil
    }

    base_variables.merge(proof_variables).compact
  end

  # Max rejections specific methods
  def handle_max_rejections_letter(application, reapply_date)
    generate_letter_if_preferred(
      application.user,
      'application_notifications_max_rejections_reached',
      {
        reapply_date_formatted: reapply_date.strftime('%B %d, %Y'),
        first_name: application.user.first_name,
        last_name: application.user.last_name,
        application_id: application.id
      }
    )
  end

  def build_max_rejections_variables(application, reapply_date)
    header_title = 'Important: Application Status Update'

    base_variables = build_base_email_variables(header_title)
    max_rejections_variables = {
      user_first_name: application.user.first_name,
      application_id: application.id,
      reapply_date_formatted: reapply_date.strftime('%B %d, %Y')
    }

    base_variables.merge(max_rejections_variables).compact
  end

  # Proof needs review reminder specific methods
  def filter_stale_reviews(applications)
    applications.select do |app|
      app.respond_to?(:needs_review_since) &&
        app.needs_review_since.present? &&
        app.needs_review_since < 3.days.ago
    end
  end

  def handle_no_stale_reviews
    Rails.logger.info('No stale reviews found, skipping reminder email')
    nil
  end

  def build_review_reminder_variables(admin, stale_reviews)
    header_title = 'Reminder: Applications Awaiting Proof Review'
    admin_dashboard_url = admin_applications_url(host: default_url_options[:host])
    stale_reviews_text_list = build_stale_reviews_list(stale_reviews)

    base_variables = build_base_email_variables(header_title)
    reminder_variables = {
      admin_first_name: admin.first_name,
      stale_reviews_count: stale_reviews.count,
      stale_reviews_text_list: stale_reviews_text_list,
      admin_dashboard_url: admin_dashboard_url
    }

    base_variables.merge(reminder_variables).compact
  end

  def build_stale_reviews_list(stale_reviews)
    stale_reviews.map do |app|
      submitted_date = app.needs_review_since&.strftime('%Y-%m-%d') || 'N/A'
      "- ID: #{app.id}, Name: #{app.user&.full_name || 'N/A'}, Submitted: #{submitted_date}"
    end.join("\n")
  end

  # Account created specific methods
  def handle_nil_constituent
    context = Rails.env.test? ? '[TEST_EDGE_CASE] ' : '[DATA_INTEGRITY] '
    Rails.logger.error("#{context}ApplicationNotificationsMailer#account_created called with nil constituent")
    nil
  end

  def handle_account_created_letter(constituent, temp_password)
    generate_letter_if_preferred(
      constituent,
      'application_notifications_account_created',
      {
        email: constituent.email,
        temp_password: temp_password,
        first_name: constituent.first_name,
        last_name: constituent.last_name
      }
    )
  end

  def build_account_created_variables(constituent, temp_password)
    header_title = 'Your MAT Application Account Has Been Created'

    base_variables = build_base_email_variables(header_title)
    account_variables = {
      constituent_first_name: constituent.first_name,
      constituent_email: constituent.email,
      temp_password: temp_password,
      sign_in_url: sign_in_url(host: default_url_options[:host]),
      header_title: header_title,
      footer_contact_email: Policy.get('support_email') || 'support@example.com',
      footer_website_url: root_url(host: default_url_options[:host]),
      footer_show_automated_message: true
    }

    base_variables.merge(account_variables).compact
  end

  def extract_recipient_email(constituent)
    constituent.is_a?(Hash) ? constituent[:email] : constituent.email
  end

  # Income threshold exceeded specific methods
  def get_income_threshold_data(constituent_params, notification_params)
    result = Notifications::IncomeThresholdService.call(constituent_params, notification_params)

    unless result.success?
      constituent_id = constituent_params.is_a?(Hash) ? constituent_params[:id] : constituent_params&.id
      Rails.logger.error("Failed to prepare income threshold data for constituent #{constituent_id}: #{result.error_message}")
      raise result.error_message
    end

    {
      constituent: result.data[:constituent],
      notification: result.data[:notification],
      threshold_data: result.data[:threshold_data],
      threshold: result.data[:threshold]
    }
  end

  def build_income_threshold_variables(service_result)
    constituent = service_result[:constituent]
    notification = service_result[:notification]
    threshold_data = service_result[:threshold_data]
    threshold = service_result[:threshold]

    header_title = 'Important Information About Your MAT Application'
    status_box_title = 'Application Status: Income Threshold Exceeded'
    status_box_message = "Based on the information provided, your household income exceeds the program's limit."

    base_variables = build_base_email_variables(header_title)
    threshold_variables = {
      constituent_first_name: constituent[:first_name],
      household_size: threshold_data[:household_size],
      annual_income_formatted: ActionController::Base.helpers.number_to_currency(notification[:annual_income]),
      threshold_formatted: ActionController::Base.helpers.number_to_currency(threshold),
      status_box_text: status_box_text(status: 'error', title: status_box_title, message: status_box_message),
      additional_notes: notification[:additional_notes]
    }

    base_variables.merge(threshold_variables).compact
  end

  # Proof submission error specific methods
  def determine_proof_error_recipient(constituent, message)
    if constituent
      {
        email: constituent.email,
        full_name: constituent.full_name
      }
    else
      {
        email: message.match(/from: ([^\s]+@[^\s]+)/)&.captures&.first || 'unknown@example.com',
        full_name: 'Email Sender'
      }
    end
  end

  def handle_proof_error_letter(constituent, application, message)
    return unless constituent.respond_to?(:communication_preference) && constituent.communication_preference == 'letter'

    generate_letter_if_preferred(
      constituent,
      'application_notifications_proof_submission_error',
      {
        error_message: message,
        first_name: constituent.first_name,
        last_name: constituent.last_name,
        application_id: application&.id
      }
    )
  end

  def build_proof_error_variables(constituent_full_name, message)
    header_title = 'Error Processing Your Proof Submission'

    base_variables = build_base_email_variables(header_title)
    error_variables = {
      constituent_full_name: constituent_full_name,
      message: message
    }

    base_variables.merge(error_variables).compact
  end

  # Registration confirmation specific methods
  def build_active_vendors_list
    active_vendors = Vendor.active.order(:business_name)
    if active_vendors.any?
      active_vendors.map { |v| "- #{v.business_name}" }.join("\n")
    else
      'No authorized vendors found at this time.'
    end
  end

  def handle_registration_letter(user, active_vendors_text_list)
    generate_letter_if_preferred(
      user,
      'application_notifications_registration_confirmation',
      {
        user_full_name: user.full_name,
        dashboard_url: constituent_portal_dashboard_url(host: default_url_options[:host]),
        new_application_url: new_constituent_portal_application_url(host: default_url_options[:host]),
        active_vendors_text_list: active_vendors_text_list
      }
    )
  end

  def build_registration_variables(user, active_vendors_text_list)
    header_title = 'Welcome to the Maryland Accessible Telecommunications Program'
    organization_name = Policy.get('organization_name') || 'Maryland Accessible Telecommunications'

    base_variables = build_base_email_variables(header_title, organization_name)
    registration_variables = {
      user_first_name: user.first_name,
      user_full_name: user.full_name,
      dashboard_url: constituent_portal_dashboard_url(host: default_url_options[:host]),
      new_application_url: new_constituent_portal_application_url(host: default_url_options[:host]),
      active_vendors_text_list: active_vendors_text_list
    }

    base_variables.merge(registration_variables).compact
  end

  # Proof received specific methods
  def build_proof_received_variables(application, proof_type)
    user = application.user
    organization_name = Policy.get('organization_name') || 'MAT Program'
    proof_type_formatted = format_proof_type(proof_type)
    header_title = "Document Received: #{proof_type_formatted.capitalize}"

    base_variables = build_base_email_variables(header_title, organization_name)
    received_variables = {
      user_first_name: user.first_name,
      organization_name: organization_name,
      proof_type_formatted: proof_type_formatted,
      all_proofs_approved_message_text: nil
    }

    base_variables.merge(received_variables).compact
  end
end
