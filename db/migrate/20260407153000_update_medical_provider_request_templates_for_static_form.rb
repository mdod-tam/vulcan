# frozen_string_literal: true

class UpdateMedicalProviderRequestTemplatesForStaticForm < ActiveRecord::Migration[8.0]
  ENGLISH_BODY = <<~TEXT.freeze
    DISABILITY CERTIFICATION FORM REQUEST

    Hello,

    We are writing to request your completion of a disability certification form for this appplicant, %<constituent_full_name>s, who is applying for the Maryland Accessible Telecommunications Program to receive accessible telecommunications equipment to support independent telephone usage.

    %<request_count_message>s and was sent on %<timestamp_formatted>s.

     INFORMATION:
    - Name: %<constituent_full_name>s
    - Date of Birth: %<constituent_dob_formatted>s
    - Phone: %<constituent_phone_formatted>s
    - Email: %<constituent_email>s
    - Address: %<constituent_address_formatted>s
    - Application ID: %<application_id>s

    To qualify for assistance through MAT, this applicant requires documentation that they have a disability that makes it difficult for them to use a standard telephone. The certification form is essential for this applicant to qualify for accessible telecommunications devices they need. To complete this form:

    1. Download the form at: %<download_form_url>s
    2. Complete all required fields
    3. Sign the form
    4. Return the completed form by email to disability_cert@mdmat.org or by fax to (410) 767-4276

    If you have questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

    Thank you for your prompt attention to this important matter.

    Sincerely,
    Maryland Accessible Telecommunications Program

    ---

    This email was sent regarding Application #%<application_id>s on behalf of %<constituent_full_name>s.
    CONFIDENTIALITY NOTICE: This email may contain confidential health information protected by state and federal privacy laws.
  TEXT

  SPANISH_BODY = <<~TEXT.freeze
    SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD

    Hola,

    Le escribimos para solicitarle que complete un formulario de certificación de discapacidad para este solicitante, %<constituent_full_name>s, quien está solicitando al Programa de Telecomunicaciones Accesibles de Maryland recibir equipos de telecomunicaciones accesibles para apoyar el uso independiente del teléfono.

    %<request_count_message>s y fue enviado el %<timestamp_formatted>s.

     INFORMACIÓN:
    - Nombre: %<constituent_full_name>s
    - Fecha de Nacimiento: %<constituent_dob_formatted>s
    - Teléfono: %<constituent_phone_formatted>s
    - Correo electrónico: %<constituent_email>s
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

  REQUIRED_VARIABLES = %w[
    constituent_full_name
    request_count_message
    timestamp_formatted
    constituent_dob_formatted
    constituent_phone_formatted
    constituent_email
    constituent_address_formatted
    application_id
    download_form_url
    support_email
  ].freeze

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
        'optional' => []
      }
    )
  end
end
