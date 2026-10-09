# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_approved"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_approved.rb)
# --------------------------------------------------
EmailTemplate.find_or_create_by!(name: 'vendor_notifications_w9_approved', format: :text, locale: 'es') do |template|
  template.subject = 'Formulario W9 Aprobado'
  template.description = 'Enviado a un proveedor cuando su formulario W9 enviado ha sido revisado y aprobado. La autorización del programa es un paso separado.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    Nos complace informarle que su formulario W9 ha sido revisado y aprobado.

    %<status_box_text>s

    La aprobación del W9 y la autorización del proveedor son pasos separados. Antes de procesar vales, el programa también debe autorizar su cuenta de proveedor. Consulte su panel para ver los pasos pendientes.

    Si tiene alguna pregunta o necesita ayuda, no dude en comunicarse con nuestro equipo de soporte al %<support_email>s o llame al (410) 767-6960.

    Gracias por su colaboración.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_text footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_approved_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
