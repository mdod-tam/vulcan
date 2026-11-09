# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'contact_change_verification', format: :text, locale: 'es') do |template|
  template.subject = 'Confirme el contacto de su cuenta'
  template.description = 'Confirms ownership of an old or proposed account email.'
  template.body = <<~TEXT
    Confirme este cambio de contacto mediante el enlace siguiente. El enlace vence veinte minutos después de la solicitud.

    %<confirmation_url>s

    Si no solicitó este cambio, comuníquese con %<support_email>s. Su contacto actual seguirá activo hasta completar todas las confirmaciones requeridas.
  TEXT
  template.variables = { 'required' => %w[confirmation_url support_email], 'optional' => [] }
  template.version = 1
end
