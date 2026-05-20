# frozen_string_literal: true

class UpdateMedicalProviderCertificationRejectedTemplatesForSecureUpload < ActiveRecord::Migration[8.0]
  ENGLISH_BODY = <<~TEXT.freeze
    MARYLAND ACCESSIBLE TELECOMMUNICATIONS

    DISABILITY CERTIFICATION FORM REJECTED

    Hello,

    We have received the disability certification form for the following individual:

    Name: %<constituent_full_name>s
    Application ID: %<application_id>s

    Unfortunately, the certification form has been rejected due to the following reason:

    %<rejection_reason>s

    NEXT STEPS

    Please submit a new disability certification form using one of the following methods:

    1. Upload the corrected form securely: %<secure_upload_url>s
    2. Download a blank form if needed: %<download_form_url>s
    3. Fax: Send the updated form to 410-767-4276

    Thank you for your assistance in helping the applicant access needed telecommunications services.

    Sincerely,
    Maryland Accessible Telecommunications Program

    ----------

    For questions, please contact us at mat.program1@maryland.gov or call 410-767-6960.
    Maryland Accessible Telecommunications (MAT) - Improving lives through accessible communication.
  TEXT

  SPANISH_BODY = <<~TEXT.freeze
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

  VARIABLES = {
    'required' => %w[constituent_full_name application_id rejection_reason download_form_url],
    'optional' => %w[secure_upload_url]
  }.freeze

  def up
    update_template!(
      locale: 'en',
      subject: 'Disability Certification Rejected',
      description: 'Sent to a medical provider when the submitted disability certification form is rejected.',
      body: ENGLISH_BODY
    )

    update_template!(
      locale: 'es',
      subject: 'Certificación de Discapacidad Rechazada',
      description: 'Enviado a un proveedor médico cuando se rechaza el formulario de certificación de discapacidad enviado.',
      body: SPANISH_BODY
    )
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def update_template!(locale:, subject:, description:, body:)
    template = EmailTemplate.find_or_initialize_by(
      name: 'medical_provider_certification_rejected',
      format: :text,
      locale: locale
    )
    template.subject = subject
    template.description = description
    template.body = body
    template.variables = VARIABLES
    template.version = 2
    template.save!
  end
end
