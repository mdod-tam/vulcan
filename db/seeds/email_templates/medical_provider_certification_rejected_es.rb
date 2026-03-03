# frozen_string_literal: true

# Seed File for "medical_provider_certification_rejected"
EmailTemplate.create_or_find_by!(name: 'medical_provider_certification_rejected', format: :text, locale: 'es') do |template|
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

    1. Correo electrónico: Responda a este correo electrónico con el formulario de certificación actualizado adjunto
    2. Fax: Envíe el formulario actualizado al 410-767-4276

    Gracias por su ayuda para que este solicitante acceda a los servicios de telecomunicaciones que necesita.

    Atentamente,
    Programa de Telecomunicaciones Accesibles de Maryland

    ----------

    Para preguntas, comuníquese con nosotros a mat.program1@maryland.gov o llame al 410-767-6960.
    Telecomunicaciones Accesibles de Maryland (MAT) - Mejorando vidas a través de la comunicación accesible.
  TEXT
  template.variables = {
    'required' => %w[constituent_full_name application_id rejection_reason],
    'optional' => %w[remaining_attempts]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_certification_rejected_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
