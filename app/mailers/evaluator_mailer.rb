# frozen_string_literal: true

class EvaluatorMailer < ApplicationMailer
  include Rails.application.routes.url_helpers
  include Mailers::SharedPartialHelpers
  include ConstituentCommunicationLabelsHelper

  def self.default_url_options
    Rails.application.config.action_mailer.default_url_options
  end

  # Expects evaluation passed via .with(evaluation: ...)
  def new_evaluation_assigned
    evaluation = params[:evaluation]
    template_name = 'evaluator_mailer_new_evaluation_assigned'
    # The assignment template has only an English seed.
    locale = 'en'

    text_template = load_email_template(template_name, locale: locale)
    variables = build_new_evaluation_variables(evaluation, template: text_template, locale: locale)
    send_email(recipient_email_for(evaluation.evaluator), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, evaluation&.evaluator, template_name)
    raise
  end

  # Expects evaluation passed via .with(evaluation: ...)
  def evaluation_submission_confirmation
    evaluation = params[:evaluation]
    template_name = 'evaluator_mailer_evaluation_submission_confirmation'
    contact = Evaluations::ContactContext.new(evaluation)
    delivery_owner = contact.communication_preference == 'letter' ? contact.address_owner : contact.email_owner
    locale = normalize_locale(delivery_owner&.locale) || normalize_locale(I18n.default_locale) || 'en'

    text_template = load_email_template(template_name, locale: locale)
    variables = build_submission_confirmation_variables(evaluation, template: text_template, locale: locale)

    return noop_letter_delivery if queue_letter_if_needed(evaluation, contact, template_name, variables, locale: locale)

    send_email(confirmation_email_for(contact), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, evaluation&.constituent, template_name)
    raise
  end

  private

  def load_email_template(template_name, locale: nil)
    find_text_template(template_name, locale: locale)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate for #{template_name}: #{e.message}"
    raise "Email templates not found for #{template_name}"
  end

  def build_new_evaluation_variables(evaluation, template:, locale: nil)
    evaluator = evaluation.evaluator
    constituent = evaluation.constituent
    application = evaluation.application
    contact = Evaluations::ContactContext.new(evaluation)

    evaluation_url = safe_evaluation_url(evaluation)
    header_title = header_title_from_template_subject(
      template: template,
      subject_variables: { application_id: application.id },
      fallback: "New Evaluation Assigned - Application ##{application.id}"
    )
    header_data = build_header_footer_data(header_title, locale: locale)

    {
      evaluator_full_name: evaluator.full_name,
      constituent_full_name: constituent.full_name,
      constituent_address_formatted: format_constituent_address(contact.address_owner),
      constituent_phone_formatted: contact.phone.presence || 'Not Provided',
      constituent_email: contact.email.presence || 'Not Provided',
      constituent_contact_method: contact_method_label(contact.phone_type),
      constituent_preferred_language: language_label(contact.locale),
      constituent_communication_modality: contact.communication_modality.presence || 'Not specified',
      constituent_delivery_preference: contact.communication_preference.to_s.humanize.presence || 'Not specified',
      evaluators_evaluation_url: evaluation_url,
      constituent_disabilities_html_list: format_disabilities_html(constituent),
      constituent_disabilities_text_list: format_disabilities_text(constituent),
      status_box_text: status_box_text(
        status: :info,
        title: 'Evaluation Assignment',
        message: 'Please contact the constituent to schedule or complete this evaluation when you have the required information.'
      ),
      **header_data
    }.compact
  end

  def build_submission_confirmation_variables(evaluation, template:, locale: nil)
    constituent = evaluation.constituent
    application = evaluation.application
    evaluator = evaluation.evaluator
    submission_date_formatted = evaluation.report_submitted_at&.strftime('%B %d, %Y at %I:%M %p %Z') || 'Not recorded'

    header_title = header_title_from_template_subject(
      template: template,
      subject_variables: { application_id: application.id },
      fallback: "Your Evaluation has been Submitted - Application ##{application.id}"
    )
    header_data = build_header_footer_data(header_title, locale: locale)

    {
      constituent_first_name: constituent.first_name,
      application_id: application.id,
      evaluator_full_name: evaluator.full_name,
      submission_date_formatted: submission_date_formatted,
      recommended_products_text_list: format_recommended_products_text(evaluation, locale: locale),
      status_box_text: status_box_text(
        status: :success,
        title: I18n.t('evaluator_mailer.status_boxes.submitted.title', locale: locale),
        message: I18n.t('evaluator_mailer.status_boxes.submitted.message', locale: locale)
      ),
      **header_data
    }.compact
  end

  def safe_evaluation_url(evaluation)
    evaluators_evaluation_url(evaluation, host: default_url_options[:host])
  rescue StandardError
    '#'
  end

  def build_header_footer_data(title, locale: nil)
    footer_contact_email = Policy.get('support_email') || 'mat.program1@maryland.gov'
    footer_website_url = ProgramContact.website_url
    footer_show_automated_message = true
    footer_organization_name = Policy.get('organization_name') || 'MAT Program'
    header_logo_url = safe_logo_url

    {
      header_text: header_text(title: title, logo_url: header_logo_url, locale: locale),
      footer_text: footer_text(
        contact_email: footer_contact_email,
        website_url: footer_website_url,
        show_automated_message: footer_show_automated_message,
        organization_name: footer_organization_name,
        locale: locale
      ),
      header_logo_url: header_logo_url,
      header_subtitle: nil,
      support_email: footer_contact_email
    }
  end

  def safe_logo_url
    ActionController::Base.helpers.asset_path('logo.png', host: default_url_options[:host])
  rescue StandardError
    nil
  end

  def format_constituent_address(constituent)
    [
      constituent.physical_address_1,
      constituent.physical_address_2,
      "#{constituent.city}, #{constituent.state} #{constituent.zip_code}"
    ].compact_blank.join("\n")
  end

  def format_disabilities_html(constituent)
    return '' if constituent.disabilities.blank?

    "<ul>#{constituent.disabilities.map { |d| "<li>#{d}</li>" }.join}</ul>"
  end

  def format_disabilities_text(constituent)
    return '' if constituent.disabilities.blank?

    constituent.disabilities.map { |d| "- #{d}" }.join("\n")
  end

  # The existing editable-template variable carries the report outcome, including recommendations outside the catalog.
  def format_recommended_products_text(evaluation, locale:)
    if evaluation.recommendation_outcome_catalog_products?
      products = evaluation.recommended_products.order(:name).map(&:name).join("\n")
      [products, evaluation.recommendation_notes.presence].compact_blank.join("\n\n")
    else
      summary = I18n.t("evaluation_confirmation.outcomes.#{evaluation.recommendation_outcome}", locale: locale)
      [summary, evaluation.recommendation_notes, I18n.t('evaluation_confirmation.staff_review', locale: locale)].compact_blank.join("\n\n")
    end
  end

  # True means the letter route handles this message, including an existing queued letter, so no email follows.
  def queue_letter_if_needed(evaluation, contact, template_name, variables, locale:)
    return false unless contact.communication_preference == 'letter'

    queue_letter_delivery(
      locale: locale,
      recipient: contact.applicant,
      print_recipient: contact.address_owner,
      template_name: template_name,
      variables: variables,
      letter_type: :evaluation_submitted,
      delivery_key: params[:delivery_request_id] || "evaluation-confirmation:#{evaluation.id}:#{evaluation.evaluation_date&.iso8601}",
      application: evaluation.application
    )
    true
  end

  def confirmation_email_for(contact)
    return if contact.email.blank?

    @delivery_contacts ||= {}
    @delivery_contacts[contact.email.downcase] = { recipient: contact.applicant, owner: contact.email_owner }
    contact.email
  end
end
