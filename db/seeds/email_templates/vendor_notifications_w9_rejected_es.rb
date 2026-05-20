# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_rejected"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_rejected.rb)
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'vendor_notifications_w9_rejected', format: :text, locale: 'es')
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
  %<w9_resubmission_instructions>s

  Una vez que haya enviado un formulario W9 corregido, nuestro equipo lo revisará de inmediato.

  Si tiene alguna pregunta o necesita ayuda, no dude en comunicarse con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

  Gracias por su cooperación.

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text vendor_business_name status_box_text rejection_reason w9_resubmission_instructions footer_text support_email],
  'optional' => %w[secure_upload_url vendor_portal_url]
}
template.version = 2
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded vendor_notifications_w9_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
