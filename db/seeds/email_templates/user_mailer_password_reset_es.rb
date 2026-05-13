# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'user_mailer_password_reset', format: :text, locale: 'es') do |template|
  template.subject = 'Instrucciones de acceso a la cuenta'
  template.description = 'Enviado cuando un usuario solicita acceso a la cuenta o restablecer su contraseña. Contiene un enlace para establecer una contraseña.'
  template.body = <<~TEXT
    Hola,

    Recibimos una solicitud de acceso a la cuenta o de restablecimiento de contraseña para %<user_email>s.

    Use este enlace seguro para establecer su contraseña y acceder a su cuenta:

    %<reset_url>s

    Este enlace caduca en 20 minutos. Si no solicitó acceso a la cuenta, puede ignorar este correo electrónico.

    ---

    ¿Tiene preguntas o necesita ayuda? Responda a este correo electrónico y nuestro equipo de soporte le ayudará.
  TEXT
  template.variables = {
    'required' => %w[user_email reset_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_mailer_password_reset_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
