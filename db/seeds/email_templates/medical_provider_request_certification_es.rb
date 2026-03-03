# frozen_string_literal: true

# Seed File for "medical_provider_request_certification"
EmailTemplate.create_or_find_by!(name: 'medical_provider_request_certification', format: :text, locale: 'es') do |template|
  template.subject = 'SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD'
  template.description = 'Enviado a un profesional certificador solicitándole que complete y envíe un formulario de certificación de discapacidad para un solicitante.'
  template.body = <<~TEXT
    SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD

    Hola,

    Le escribimos para solicitarle que complete un formulario de certificación de discapacidad para este solicitante, %<constituent_full_name>s, quien está solicitando al Programa de Telecomunicaciones Accesibles de Maryland recibir equipos de telecomunicaciones accesibles para apoyar el uso independiente del teléfono.

    %<request_count_message>s y fue enviado el %<timestamp_formatted>s.

     INFORMACIÓN:
    - Nombre: %<constituent_full_name>s
    - Fecha de Nacimiento: %<constituent_dob_formatted>s
    - Dirección: %<constituent_address_formatted>s
    - ID de Solicitud: %<application_id>s

    Para calificar para la asistencia a través de MAT, este solicitante requiere documentación de que tiene una discapacidad que le dificulta usar un teléfono estándar. El formulario de certificación es esencial para que este solicitante califique para los dispositivos de telecomunicaciones accesibles que necesita. Para completar este formulario:

    1. Descargue el formulario en: %<download_form_url>s
    2. Complete todos los campos obligatorios
    3. Firme el formulario
    4. Devuelva el formulario completado por correo electrónico a disability_cert@mdmat.org o por fax al (410) 767-4276

    Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    Gracias por su pronta atención a este importante asunto.

    Atentamente,
    Programa de Telecomunicaciones Accesibles de Maryland

    ---

    Este correo electrónico fue enviado con respecto a la Solicitud #%<application_id>s en nombre de %<constituent_full_name>s.
    AVISO DE CONFIDENCIALIDAD: Este correo electrónico puede contener información de salud confidencial protegida por las leyes de privacidad estatales y federales.
  TEXT
  template.variables = {
    'required' => %w[constituent_full_name request_count_message timestamp_formatted constituent_dob_formatted constituent_address_formatted application_id
                     download_form_url support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_request_certification_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
