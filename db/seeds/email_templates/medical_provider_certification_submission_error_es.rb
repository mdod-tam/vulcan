# frozen_string_literal: true

# Seed File for "medical_provider_certification_submission_error"
EmailTemplate.create_or_find_by!(name: 'medical_provider_certification_submission_error', format: :text, locale: 'es') do |template|
  template.subject = 'Error de Envío de Certificación Médica'
  template.description = 'Enviado a un proveedor médico cuando ocurre un error durante el procesamiento automático de su formulario de certificación enviado.'
  template.body = <<~TEXT
    Error de Envío de Certificación Médica

    Hola,

    Encontramos un error al procesar su reciente envío de certificación médica de %<medical_provider_email>s.

    El mensaje de error es: %<error_message>s

    Por favor revise el error y vuelva a enviar el formulario de certificación a disability_cert@mdmat.org o por fax al (410) 767-4276.

    Si continúa teniendo problemas o tiene preguntas, comuníquese con nosotros a mat.program1@maryland.gov o llame al 410-767-6960.

    Atentamente,
    Programa de Telecomunicaciones Accesibles de Maryland

    ---

    Este es un mensaje automático. Por favor, no responda directamente a este correo electrónico.
  TEXT
  template.variables = {
    'required' => %w[medical_provider_email error_message],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_certification_submission_error_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
