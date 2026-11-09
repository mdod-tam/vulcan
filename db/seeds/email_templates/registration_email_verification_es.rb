# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'registration_email_verification', format: :text, locale: 'es') do |template|
  template.subject = 'Confirme su correo electrónico para continuar con MAT'
  template.description = 'Confirma el acceso a un correo electrónico antes del registro. El enlace no inicia sesión en una cuenta existente.'
  template.body = <<~TEXT
    Hola:

    Alguien solicitó continuar con MAT usando esta dirección de correo electrónico.

    Confirme su correo electrónico y continúe:
    %<verification_url>s

    Termine de crear su cuenta antes de que caduque este enlace: %<expires_at>s.
    Confirmar su correo electrónico no inicia sesión en una cuenta existente.

    Si no hizo esta solicitud, ignore este correo. Su cuenta no ha cambiado.
  TEXT
  template.variables = { 'required' => %w[verification_url expires_at], 'optional' => [] }
  template.version = 1
end
