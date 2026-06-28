# frozen_string_literal: true

# Seed File for "user_mailer_email_verification.rb"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'user_mailer_email_verification', format: :text, locale: 'es') do |template|
  template.subject = 'Por favor confirme su dirección de correo electrónico'
  template.description = 'Enviado a un usuario para verificar su dirección de correo electrónico usando el enlace de verificación.'
  template.body = <<~TEXT
    Hola,

    Esto es para confirmar que %<user_email>s es el correo electrónico que ha elegido usar en su cuenta. Si alguna vez pierde su contraseña, ahí es donde enviaremos un enlace de restablecimiento.

    Use el enlace de verificación de correo electrónico para confirmar que recibió este correo electrónico.

    Enlace de verificación de correo electrónico:
    %<verification_url>s

    ---

    ¿Tiene preguntas o necesita ayuda? Simplemente responda a este correo electrónico y nuestro equipo le ayudará a resolverlo.
  TEXT
  template.variables = {
    'required' => %w[user_email verification_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_notifications_email_confirmation_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
