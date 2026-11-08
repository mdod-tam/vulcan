# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'contact_change_notice', format: :text, locale: 'es') do |template|
  template.subject = 'Aviso de seguridad del contacto de su cuenta'
  template.description = 'Account-owner notice sent to an immutable email snapshot.'
  template.body = <<~TEXT
    %<message>s

    Si no solicitó este cambio, comuníquese de inmediato con %<support_email>s.
  TEXT
  template.variables = { 'required' => %w[message support_email], 'optional' => [] }
  template.version = 1
end
