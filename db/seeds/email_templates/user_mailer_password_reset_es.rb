# frozen_string_literal: true

# Seed File for "user_mailer_password_reset"
# (Suggest saving as db/seeds/email_templates/user_mailer_password_reset.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'user_mailer_password_reset', format: :text, locale: 'es') do |template|
  template.subject = 'Instrucciones para restablecer contraseña'
  template.description = 'Enviado cuando un usuario solicita restablecer su contraseña. Contiene un enlace para establecer una nueva contraseña.'
  template.body = <<~TEXT
    Hola,

    ¿No puede recordar su contraseña para %<user_email>s? Está bien, sucede. Simplemente haga clic en el enlace a continuación para establecer una nueva.

    %<reset_url>s

    Si no solicitó un restablecimiento de contraseña, puede ignorar de manera segura este correo electrónico, caduca en 20 minutos. Solo alguien con acceso a esta cuenta de correo electrónico puede restablecer su contraseña.

    ---

    ¿Tiene preguntas o necesita ayuda? Simplemente responda a este correo electrónico y nuestro equipo de soporte le ayudará a resolverlo.
  TEXT
  template.variables = {
    'required' => %w[user_email reset_url],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded user_mailer_password_reset_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
