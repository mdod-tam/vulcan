# frozen_string_literal: true

class EvaluatorMailer < ApplicationMailer
  include ConstituentCommunicationLabelsHelper

  # Expects .with(evaluation:, recipient:, operation_id:). The recipient is the evaluator the notice was
  # written for, never whoever holds the evaluation when the job runs.
  def new_evaluation_assigned
    evaluation = params[:evaluation]
    evaluator = params[:recipient]
    superseded = superseded_assignment_delivery(evaluation, operation_id: params[:operation_id], assignee: evaluator)
    return superseded if superseded

    # The assignment template has only an English seed.
    locale = 'en'

    deliver_notification('evaluator_mailer_new_evaluation_assigned', recipient: evaluator, locale: locale) do |template|
      build_new_evaluation_variables(evaluation, evaluator, template: template, locale: locale)
    end
  end

  # Expects evaluation passed via .with(evaluation: ...)
  def evaluation_submission_confirmation
    evaluation = params[:evaluation]
    template_name = 'evaluator_mailer_evaluation_submission_confirmation'
    contact = Applications::ContactContext.new(application: evaluation.application)
    locale = resolve_template_locale(recipient: contact.applicant)

    text_template = notification_template(template_name, locale)
    variables = build_submission_confirmation_variables(evaluation, template: text_template, locale: locale)

    return noop_letter_delivery if queue_letter_if_needed(evaluation, contact, template_name, variables, locale: locale)

    send_email(recipient_email_for(contact.applicant), text_template, variables)
  rescue StandardError => e
    log_mail_error(e, evaluation&.constituent, template_name)
    raise
  end

  private

  def build_new_evaluation_variables(evaluation, evaluator, template:, locale: nil)
    constituent = evaluation.constituent
    application = evaluation.application
    contact = Applications::ContactContext.new(application: application)

    evaluation_url = safe_evaluation_url(evaluation)
    envelope = envelope_variables(template: template, locale: locale, subject_variables: { application_id: application.id },
                                  fallback_title: "New Evaluation Assigned - Application ##{application.id}", organization_name: 'MAT Program')

    {
      evaluator_full_name: evaluator.full_name,
      constituent_full_name: constituent.full_name,
      constituent_address_formatted: constituent_address_text(contact.address_owner),
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
      **envelope
    }.compact
  end

  def build_submission_confirmation_variables(evaluation, template:, locale: nil)
    constituent = evaluation.constituent
    application = evaluation.application
    evaluator = evaluation.evaluator
    submission_date_formatted = evaluation.report_submitted_at&.strftime('%B %d, %Y at %I:%M %p %Z') || 'Not recorded'

    envelope = envelope_variables(template: template, locale: locale, subject_variables: { application_id: application.id },
                                  fallback_title: "Your Evaluation has been Submitted - Application ##{application.id}",
                                  organization_name: 'MAT Program')

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
      **envelope
    }.compact
  end

  def safe_evaluation_url(evaluation)
    evaluators_evaluation_url(evaluation, host: default_url_options[:host])
  rescue StandardError
    '#'
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
    return false unless prefers_letter_delivery?(contact.applicant)

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
end
