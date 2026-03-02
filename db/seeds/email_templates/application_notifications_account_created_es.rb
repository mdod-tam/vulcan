# frozen_string_literal: true

# Seed File for "application_notifications_account_created"
# Took out the login details as they are not needed for the account creation notification for the internal release.
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_account_created', format: :text, locale: 'es') do |template|
  template.subject = 'Su Cuenta de Telecomunicaciones Accesibles de Maryland'
  template.description = 'Sent when an application is received and a constituent account is created, providing initial login details.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<constituent_first_name>s,

    Hemos recibido su solicitud de equipos y servicios de telecomunicaciones accesibles.

    Le enviaremos actualizaciones importantes y documentos sobre el estado de su solicitud mientras la revisamos.

    Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name footer_text support_email],
    'optional' => %w[constituent_email temp_password sign_in_url]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_account_created_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
