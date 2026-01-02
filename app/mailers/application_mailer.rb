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
    if !template.enabled?
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

  def set_common_variables
    @current_year = Time.current.year
    @organization_name = 'Maryland Accessible Telecommunications Program'
    @organization_email = 'no_reply@mdmat.org'
    @organization_website = 'https://mdmat.org'
  end
end
