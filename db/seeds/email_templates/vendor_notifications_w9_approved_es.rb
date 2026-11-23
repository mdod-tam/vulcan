# frozen_string_literal: true

EmailTemplate.find_or_create_by!(name: 'vendor_notifications_w9_approved', format: :text, locale: 'es') do |template|
  template.subject = 'Formulario W9 Aprobado'
  template.description = 'Enviado a un proveedor cuando su formulario W9 enviado ha sido revisado y aprobado. La autorización del programa es un paso separado.'
  template.body = <<~TEXT
    %<header_text>s

    Hola, %<vendor_business_name>s,

    Aprobamos su W9. Consulte el panel de proveedores para ver si le queda algún paso antes de canjear vales.

    Si necesita ayuda, escriba a %<support_email>s o llame al 410-767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_approved_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
