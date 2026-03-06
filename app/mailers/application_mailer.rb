# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  class NoopDelivery
    attr_reader :channel, :reason

    def initialize(channel: nil, reason: nil)
      @channel = channel&.to_s
      @reason = reason&.to_s
    end

    def deliver_later = self
    def deliver_now = self
  end

  helper :mailer

  default(
    from: 'no_reply@mdmat.org'
  )

  layout 'mailer'
  before_action :set_common_variables

  # Common email sender used by all mailers
  # Checks if template is enabled before sending and logs warnings if disabled
  def send_email(recipient_email, template, variables, mail_options = {})
    unless template.enabled?
      Rails.logger.warn("Email template '#{template.name}' is disabled. Skipping email to #{recipient_email}")
      return
    end

    rendered_subject, rendered_text_body = template.render(**variables)

    # Apply subject override if provided
    subject_override = mail_options.delete(:subject_override)
    rendered_subject = subject_override.call(rendered_subject) if subject_override.present?

    default_options = {
      to: recipient_email,
      subject: rendered_subject,
      message_stream: 'notifications'
    }

    mail(default_options.merge(mail_options)) do |format|
      format.text { render plain: rendered_text_body }
    end
  end

  private

  def noop_delivery(channel: nil, reason: nil)
    NoopDelivery.new(channel: channel, reason: reason)
  end

  def noop_letter_delivery(reason: 'preference')
    noop_delivery(channel: :letter, reason: reason)
  end

  def prefers_letter_delivery?(recipient, override: nil)
    return override.to_s == 'letter' if override.present?

    preference =
      if recipient.respond_to?(:effective_communication_preference)
        recipient.effective_communication_preference
      elsif recipient.respond_to?(:communication_preference)
        recipient.communication_preference
      end

    preference.to_s == 'letter'
  end

  def recipient_email_for(recipient)
    return recipient.effective_email if recipient.respond_to?(:effective_email) && recipient.effective_email.present?
    return recipient.email if recipient.respond_to?(:email)

    nil
  end

  def queue_letter_delivery(recipient:, template_name:, variables:, letter_type: nil, application: nil)
    print_recipient = letter_recipient_for(recipient)
    letter_variables = variables.respond_to?(:to_h) ? variables.to_h.deep_symbolize_keys : variables.dup
    letter_variables[:application] = application if application.present?

    Letters::TextTemplateToPdfService.new(
      template_name: template_name,
      recipient: print_recipient,
      variables: letter_variables,
      letter_type: letter_type
    ).queue_for_printing
  end

  def letter_recipient_for(recipient)
    return recipient unless recipient.respond_to?(:dependent?) && recipient.dependent?
    return recipient unless recipient.respond_to?(:guardian_for_contact) && recipient.guardian_for_contact.present?

    recipient.guardian_for_contact
  end

  def find_text_template(template_name, recipient: nil, locale: nil)
    # Locale-specific template selection is tracked in PR70.
    # Routing changes in this branch use the existing name+format lookup.
    EmailTemplate.find_by!(name: template_name, format: :text)
  end

  def set_common_variables
    @current_year = Time.current.year
    @organization_name = 'Maryland Accessible Telecommunications Program'
    @organization_email = 'no_reply@mdmat.org'
    @organization_website = 'https://mdmat.org'
  end
end
