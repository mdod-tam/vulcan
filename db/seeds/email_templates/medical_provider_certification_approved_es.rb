# frozen_string_literal: true

# Seed File for "medical_provider_certification_approved"
EmailTemplate.create_or_find_by!(name: 'medical_provider_certification_approved', format: :text, locale: 'es') do |template|
  template.subject = 'Certificación de Discapacidad Firmada Recibida y Aprobada'
  template.description = 'Enviado al firmante cuando se recibe y aprueba su copia firmada de la certificación de discapacidad.'
  template.body = <<~TEXT
    TELECOMUNICACIONES ACCESIBLES DE MARYLAND

    CERTIFICACIÓN DE DISCAPACIDAD FIRMADA RECIBIDA

    Hola,

    Esto es para confirmar que su copia firmada de la certificación de discapacidad ha sido recibida y aprobada.

    Nombre: %<constituent_full_name>s
    ID de Solicitud: %<application_id>s

    No se necesita ninguna otra acción en este momento.

    Gracias por tomarse el tiempo de completar y enviar la certificación firmada.

    Atentamente,
    Programa de Telecomunicaciones Accesibles de Maryland

    ----------

    Para preguntas, comuníquese con nosotros a mat.program1@maryland.gov o llame al 410-767-6960.
  TEXT
  template.variables = {
    'required' => %w[constituent_full_name application_id],
    'optional' => %w[support_email]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_certification_approved_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
