# frozen_string_literal: true

class UserMailer < ApplicationMailer
  # NOTE: These simple emails don't use shared partials like header/footer.

  def password_reset
    user = params[:user]
    template_name = 'user_mailer_password_reset'
    variables = {}
    token = user.generate_token_for(:password_reset)
    reset_url = edit_password_url(token: token, **CanonicalPublicUrlOptions.call)

    locale = resolve_template_locale(recipient: user)
    text_template = find_text_template(template_name, locale: locale)

    variables = {
      user_email: user.email,
      reset_url: reset_url
    }.compact

    send_email(user.email, text_template, variables, { message_stream: 'outbound' })
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "Missing EmailTemplate (text format) for #{template_name}: #{e.message}"
    raise "Email template (text format) not found for #{template_name}"
  rescue StandardError => e
    log_mail_error(e, user, template_name, variables)
    raise e
  end
end
