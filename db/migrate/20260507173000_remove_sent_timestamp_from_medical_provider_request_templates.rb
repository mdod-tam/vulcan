# frozen_string_literal: true

class RemoveSentTimestampFromMedicalProviderRequestTemplates < ActiveRecord::Migration[8.0]
  ENGLISH_BODY = <<~TEXT
    DISABILITY CERTIFICATION FORM REQUEST

    Hello,

    %<constituent_full_name>s recently applied to the Maryland Accessible Telecommunications Program for equipment that supports independent telephone use. They listed you as a professional who can certify that they have a disability.

    %<request_count_message>s

     INFORMATION:
    - Name: %<constituent_full_name>s
    - Date of Birth: %<constituent_dob_formatted>s
    - Phone: %<constituent_phone_formatted>s
    - Email: %<constituent_email>s
    - Address: %<constituent_address_formatted>s
    - Application ID: %<application_id>s

    To qualify for assistance through MAT, this applicant requires documentation that they have a disability that makes it difficult for them to use a standard telephone. The certification form is essential for this applicant to qualify for accessible telecommunications devices they need. To complete this form:

    %<certification_submission_instructions>s

    If you have questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

    Thank you for your prompt attention to this important matter.

    Sincerely,
    Maryland Accessible Telecommunications Program

    ---

    This email was sent regarding Application #%<application_id>s on behalf of %<constituent_full_name>s.
    CONFIDENTIALITY NOTICE: This email may contain confidential health information protected by state and federal privacy laws.
  TEXT

  SPANISH_BODY = <<~TEXT
    SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD

    Hola,

    Le escribimos para solicitarle que complete un formulario de certificación de discapacidad para este solicitante, %<constituent_full_name>s, quien está solicitando al Programa de Telecomunicaciones Accesibles de Maryland recibir equipos de telecomunicaciones accesibles para apoyar el uso independiente del teléfono.

    %<request_count_message>s

     INFORMACIÓN:
    - Nombre: %<constituent_full_name>s
    - Fecha de Nacimiento: %<constituent_dob_formatted>s
    - Teléfono: %<constituent_phone_formatted>s
    - Correo electrónico: %<constituent_email>s
    - Dirección: %<constituent_address_formatted>s
    - ID de Solicitud: %<application_id>s

    Para calificar para la asistencia a través de MAT, este solicitante requiere documentación de que tiene una discapacidad que le dificulta usar un teléfono estándar. El formulario de certificación es esencial para que este solicitante califique para los dispositivos de telecomunicaciones accesibles que necesita. Para completar este formulario:

    %<certification_submission_instructions>s

    Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    Gracias por su pronta atención a este importante asunto.

    Atentamente,
    Programa de Telecomunicaciones Accesibles de Maryland

    ---

    Este correo electrónico fue enviado con respecto a la Solicitud #%<application_id>s en nombre de %<constituent_full_name>s.
    AVISO DE CONFIDENCIALIDAD: Este correo electrónico puede contener información de salud confidencial protegida por las leyes de privacidad estatales y federales.
  TEXT

  REQUIRED_VARIABLES = %w[
    constituent_full_name
    request_count_message
    constituent_dob_formatted
    constituent_phone_formatted
    constituent_email
    constituent_address_formatted
    application_id
    certification_submission_instructions
    support_email
  ].freeze

  OPTIONAL_VARIABLES = %w[download_form_url secure_upload_url].freeze

  def up
    update_template(locale: 'en', body: ENGLISH_BODY)
    update_template(locale: 'es', body: SPANISH_BODY)
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def update_template(locale:, body:)
    template = EmailTemplate.find_by(
      name: 'medical_provider_request_certification',
      format: :text,
      locale: locale
    )
    return unless template

    template.update!(
      body: body,
      variables: {
        'required' => REQUIRED_VARIABLES,
        'optional' => OPTIONAL_VARIABLES
      }
    )
  end
end
