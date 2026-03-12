# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_rejected"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_rejected.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_rejected', format: :text, locale: 'es') do |template|
  template.subject = 'El Formulario W9 Requiere Corrección'
  template.description = 'Enviado a un proveedor cuando su formulario W9 enviado ha sido rechazado y requiere correcciones.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    Hemos revisado su formulario W9 enviado y hemos encontrado que requiere algunas correcciones antes de que podamos continuar.

    %<status_box_text>s

    Motivo del Rechazo:
    %<rejection_reason>s

    Próximos Pasos:
    1. Por favor inicie sesión en su cuenta de proveedor: %<vendor_portal_url>s
    2. Navegue a la configuración de su perfil
    3. Suba un formulario W9 corregido

    Una vez que haya enviado un formulario W9 corregido, nuestro equipo lo revisará de inmediato.

    Si tiene alguna pregunta o necesita ayuda, no dude en comunicarse con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    Gracias por su cooperación.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_text rejection_reason vendor_portal_url footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
