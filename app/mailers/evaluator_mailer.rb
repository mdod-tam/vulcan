# frozen_string_literal: true

class EvaluatorMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  # Include helpers for rendering shared partials
  include Mailers::SharedPartialHelpers # Use the extracted shared helper module

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # Notify an evaluator that a new evaluation has been assigned
  # Expects evaluation passed via .with(evaluation: ...)
  def new_evaluation_assigned
    evaluation = params[:evaluation]
    template_name = 'evaluator_mailer_new_evaluation_assigned'

    text_template = load_email_template(template_name)
    variables = build_new_evaluation_variables(evaluation)
    send_email(evaluation.evaluator.email, text_template, variables)
  rescue StandardError => e
    log_email_error(e, evaluation&.evaluator, template_name, variables)
    raise
  end

  # Notify a constituent that their evaluation has been submitted
  # Expects evaluation passed via .with(evaluation: ...)
  def evaluation_submission_confirmation
    evaluation = params[:evaluation]
    template_name = 'evaluator_mailer_evaluation_submission_confirmation'

    text_template = load_email_template(template_name)
    variables = build_submission_confirmation_variables(evaluation)

    queue_letter_if_needed(evaluation, template_name, variables)
    send_email(evaluation.constituent.email, text_template, variables)
  rescue StandardError => e
    log_submission_error(e, evaluation)
    raise
  end

  # Class method to manage queued letters using class instance variable
  def self.queued_letters
    @queued_letters ||= Set.new
  end

  # Check if a letter has already been queued for this evaluation and letter type
  def letter_already_queued?(evaluation, letter_type)
    # Use a class instance variable to track queued letters across instances
    key = "#{evaluation.id}_#{letter_type}"

    if self.class.queued_letters.include?(key)
      true
    else
      self.class.queued_letters.add(key)
      # Clean up old entries periodically to prevent memory leaks
      self.class.queued_letters.clear if self.class.queued_letters.size > 1000
      false
    end
  end

  private

  # Load email template with error handling
  def load_email_template(template_name)
    EmailTemplate.find_by!(name: template_name, format: :text)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email templates not found for #{template_name}"
  end

  # Build variables hash for new evaluation assignment email
  def build_new_evaluation_variables(evaluation)
    evaluator = evaluation.evaluator
    constituent = evaluation.constituent
    application = evaluation.application

    evaluation_url = safe_evaluation_url(evaluation)
    header_title = "New Evaluation Assigned - Application ##{application.id}"
    header_data = build_header_footer_data(header_title)

    {
      evaluator_full_name: evaluator.full_name,
      constituent_full_name: constituent.full_name,
      constituent_address_formatted: format_constituent_address(constituent),
      constituent_phone_formatted: constituent.phone || 'Not Provided',
      constituent_email: constituent.email,
      evaluators_evaluation_url: evaluation_url,
      constituent_disabilities_html_list: format_disabilities_html(constituent),
      constituent_disabilities_text_list: format_disabilities_text(constituent),
      **header_data
    }.compact
  end

  # Build variables hash for evaluation submission confirmation email
  def build_submission_confirmation_variables(evaluation)
    constituent = evaluation.constituent
    application = evaluation.application
    evaluator = evaluation.evaluator
    submission_date_formatted = evaluation.try(:submitted_at)&.strftime('%B %d, %Y at %I:%M %p %Z') || 'Not Provided'

    header_title = "Your Evaluation has been Submitted - Application ##{application.id}"
    header_data = build_header_footer_data(header_title)

    {
      constituent_first_name: constituent.first_name,
      application_id: application.id,
      evaluator_full_name: evaluator.full_name,
      submission_date_formatted: submission_date_formatted,
      **header_data
    }.compact
  end

  # Safely get evaluation URL with fallback
  def safe_evaluation_url(evaluation)
    evaluators_evaluation_url(evaluation, host: default_url_options[:host])
  rescue StandardError
    '#'
  end

  # Build header and footer data for email template
  def build_header_footer_data(title)
    footer_contact_email = Policy.get('support_email') || 'support@example.com'
    footer_website_url = root_url(host: default_url_options[:host])
    footer_show_automated_message = true
    footer_organization_name = Policy.get('organization_name') || 'MAT Program'
    header_logo_url = safe_logo_url

    {
      header_text: header_text(title: title, logo_url: header_logo_url),
      footer_text: footer_text(
        contact_email: footer_contact_email,
        website_url: footer_website_url,
        show_automated_message: footer_show_automated_message,
        organization_name: footer_organization_name
      ),
      header_logo_url: header_logo_url,
      header_subtitle: nil
    }
  end

  # Safely get logo URL with fallback
  def safe_logo_url
    ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
  rescue StandardError
    nil
  end

  # Format constituent address for display
  def format_constituent_address(constituent)
    [
      constituent.physical_address_1,
      constituent.physical_address_2,
      "#{constituent.city}, #{constituent.state} #{constituent.zip_code}"
    ].compact_blank.join("\n")
  end

  # Format disabilities as HTML list
  def format_disabilities_html(constituent)
    return '' if constituent.disabilities.blank?

    "<ul>#{constituent.disabilities.map { |d| "<li>#{d}</li>" }.join}</ul>"
  end

  # Format disabilities as text list
  def format_disabilities_text(constituent)
    return '' if constituent.disabilities.blank?

    constituent.disabilities.map { |d| "- #{d}" }.join("\n")
  end


  # Queue letter if constituent prefers print communication
  def queue_letter_if_needed(evaluation, template_name, variables)
    constituent = evaluation.constituent
    return unless constituent.communication_preference == 'letter'
    return if letter_already_queued?(evaluation, 'evaluation_submission_confirmation')

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: constituent,
      variables: variables.slice(:constituent_first_name, :application_id, :evaluator_full_name, :submission_date_formatted)
    ).queue_for_printing
  end

  # Log submission confirmation errors
  def log_submission_error(error, evaluation)
    Rails.logger.error("Failed to send evaluation submission confirmation email for evaluation #{evaluation&.id}: #{error.message}")
    Rails.logger.error(error.backtrace.join("\n"))
  end

  # Log email delivery errors
  def log_email_error(error, evaluator, template_name, variables = {})
    Event.create!(
      user: evaluator,
      action: 'email_delivery_error',
      user_agent: Current.user_agent,
      ip_address: Current.ip_address,
      metadata: {
        error_message: error.message,
        error_class: error.class.name,
        template_name: template_name,
        variables: variables.except(:header_html, :header_text, :footer_html, :footer_text, :constituent_disabilities_html_list,
                                    :constituent_disabilities_text_list),
        backtrace: error.backtrace&.first(5)
      }
    )
  end
end
