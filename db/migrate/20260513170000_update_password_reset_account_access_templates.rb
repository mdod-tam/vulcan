# frozen_string_literal: true

class UpdatePasswordResetAccountAccessTemplates < ActiveRecord::Migration[8.0]
  BODIES = {
    'en' => <<~TEXT,
      Hello,

      We received a request for account access or a password reset for %<user_email>s.

      Use this secure link to set your password and access your account:

      %<reset_url>s

      This link expires in 20 minutes. If you did not request account access, you can safely ignore this email.

      ---

      Have questions or need help? Reply to this email and our support team will help.
    TEXT
    'es' => <<~TEXT
      Hola,

      Recibimos una solicitud de acceso a la cuenta o de restablecimiento de contraseña para %<user_email>s.

      Use este enlace seguro para establecer su contraseña y acceder a su cuenta:

      %<reset_url>s

      Este enlace caduca en 20 minutos. Si no solicitó acceso a la cuenta, puede ignorar este correo electrónico.

      ---

      ¿Tiene preguntas o necesita ayuda? Responda a este correo electrónico y nuestro equipo de soporte le ayudará.
    TEXT
  }.freeze

  SUBJECTS = {
    'en' => 'Account Access Instructions',
    'es' => 'Instrucciones de acceso a la cuenta'
  }.freeze

  DESCRIPTIONS = {
    'en' => 'Sent when a user requests account access or a password reset. Contains a link to set a password.',
    'es' => 'Enviado cuando un usuario solicita acceso a la cuenta o restablecer su contraseña. Contiene un enlace para establecer una contraseña.'
  }.freeze

  def up
    BODIES.each do |locale, body|
      template = EmailTemplate.find_or_initialize_by(
        name: 'user_mailer_password_reset',
        format: :text,
        locale: locale
      )
      template.update!(
        subject: SUBJECTS.fetch(locale),
        description: DESCRIPTIONS.fetch(locale),
        body: body,
        variables: {
          'required' => %w[user_email reset_url],
          'optional' => []
        }
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
