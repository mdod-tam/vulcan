# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
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

  def resolve_template_locale(recipient: nil, locale: nil)
    explicit_locale = locale.to_s.presence
    recipient_locale = recipient.locale.to_s.presence if recipient.respond_to?(:locale)

    explicit_locale || recipient_locale || I18n.locale.to_s.presence || I18n.default_locale.to_s
  end

  def find_text_template(template_name, recipient: nil, locale: nil)
    resolved_locale = resolve_template_locale(recipient: recipient, locale: locale)
    EmailTemplate.find_by!(name: template_name, format: :text, locale: resolved_locale)
  rescue ActiveRecord::RecordNotFound
    fallback_locale = I18n.default_locale.to_s
    raise if resolved_locale == fallback_locale

    Rails.logger.debug { "No #{resolved_locale} template for #{template_name}, falling back to #{fallback_locale}" }
    EmailTemplate.find_by!(name: template_name, format: :text, locale: fallback_locale)
  end

  def set_common_variables
    @current_year = Time.current.year
    @organization_name = 'Maryland Accessible Telecommunications Program'
    @organization_email = 'no_reply@mdmat.org'
    @organization_website = 'https://mdmat.org'
  end
end
