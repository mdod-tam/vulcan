# frozen_string_literal: true

class UserMailer < ApplicationMailer
  # NOTE: These simple emails don't use shared partials like header/footer.

  def password_reset
    user = params[:user]
    token = user.generate_token_for(:password_reset)
    reset_url = edit_password_url(token: token, host: default_url_options[:host])

    template_name = 'user_mailer_password_reset'
    locale = resolve_template_locale(recipient: user)
    text_template = find_text_template(template_name, locale: locale)

    variables = {
      user_email: user.email,
      reset_url: reset_url
    }.compact

    send_email(user.email, text_template, variables, { message_stream: 'user-email' })
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate (text format) for #{template_name}: #{e.message}"
    raise "Email template (text format) not found for #{template_name}"
  rescue StandardError => e
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name,
        variables: variables,
        backtrace: e.backtrace&.first(5)
      }
    )
    raise e
  end

  def email_verification
    user = params[:user]
    token = user.generate_token_for(:email_verification)
    verification_url = verify_constituent_portal_application_url(id: user.id, token: token,
                                                                 host: default_url_options[:host])

    template_name = 'user_mailer_email_verification'
    locale = resolve_template_locale(recipient: user)
    text_template = find_text_template(template_name, locale: locale)

    variables = {
      user_email: user.email,
      verification_url: verification_url
    }.compact

    send_email(user.email, text_template, variables, { message_stream: 'outbound' })
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate (text format) for #{template_name}: #{e.message}"
    raise "Email template (text format) not found for #{template_name}"
  rescue StandardError => e
    AuditEventService.log(
      actor: user,
      action: 'email_delivery_error',
      auditable: user,
      metadata: {
        user_agent: Current.user_agent,
        ip_address: Current.ip_address,
        error_message: e.message,
        error_class: e.class.name,
        template_name: template_name,
        variables: variables,
        backtrace: e.backtrace&.first(5)
      }
    )
    raise e
  end
end
