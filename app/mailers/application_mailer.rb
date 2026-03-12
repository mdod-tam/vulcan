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

  def resolve_template_locale(recipient: nil)
    recipient_locale = normalize_locale(recipient.locale) if recipient.respond_to?(:locale)
    default_locale = normalize_locale(I18n.default_locale) || 'en'

    recipient_locale || default_locale
  end

  def find_text_template(template_name, locale: nil)
    resolved_locale = normalize_locale(locale) || resolve_template_locale
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

  def normalize_locale(locale)
    candidate = locale.to_s.strip
    return nil if candidate.empty?

    candidate.tr('_', '-').split('-').first.downcase
  end

  def interpolate_template_text(template_text, variables = {})
    rendered_text = template_text.to_s.dup
    variables.each do |key, value|
      rendered_text = rendered_text.gsub("%{#{key}}", value.to_s)
      rendered_text = rendered_text.gsub("%<#{key}>s", value.to_s)
    end
    rendered_text
  end

  def header_title_from_template_subject(template:, subject_variables: {}, fallback: '')
    return fallback.to_s if template.blank?

    rendered_subject = interpolate_template_text(template.subject, subject_variables).strip
    rendered_subject.presence || fallback.to_s
  rescue StandardError
    fallback.to_s
  end
end
