# frozen_string_literal: true

# Seed File for Spanish "medical_provider_certification_rejected"
scope = { name: 'medical_provider_certification_rejected', format: :text }
scope[:locale] = 'es' if EmailTemplate.column_names.include?('locale')

template = EmailTemplate.find_or_initialize_by(scope)
template.subject = 'Certificación de Discapacidad Rechazada'
template.description = 'Enviado a un proveedor médico cuando se rechaza el formulario de certificación de discapacidad enviado.'
template.body = <<~TEXT
  TELECOMUNICACIONES ACCESIBLES DE MARYLAND

  FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD RECHAZADO

  Hola,

  Hemos recibido el formulario de certificación de discapacidad para la siguiente persona:

  Nombre: %<constituent_full_name>s
  ID de Solicitud: %<application_id>s

  Lamentablemente, el formulario de certificación ha sido rechazado por el siguiente motivo:

  %<rejection_reason>s

  PRÓXIMOS PASOS

  Por favor envíe un nuevo formulario de certificación de discapacidad utilizando uno de los siguientes métodos:

  1. Suba el formulario corregido de forma segura: %<secure_upload_url>s
  2. Descargue un formulario en blanco si lo necesita: %<download_form_url>s
  3. Fax: Envíe el formulario actualizado al 410-767-4276

  Gracias por su ayuda para que este solicitante acceda a los servicios de telecomunicaciones que necesita.

  Atentamente,
  Programa de Telecomunicaciones Accesibles de Maryland

  ----------

  Para preguntas, comuníquese con nosotros a mat.program1@maryland.gov o llame al 410-767-6960.
  Telecomunicaciones Accesibles de Maryland (MAT) - Mejorando vidas a través de la comunicación accesible.
TEXT
template.variables = {
  'required' => %w[constituent_full_name application_id rejection_reason download_form_url],
  'optional' => %w[secure_upload_url]
}
template.version = 2
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded medical_provider_certification_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
