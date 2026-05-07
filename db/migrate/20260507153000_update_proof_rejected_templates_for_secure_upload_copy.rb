# frozen_string_literal: true

class UpdateProofRejectedTemplatesForSecureUploadCopy < ActiveRecord::Migration[8.0]
  ENGLISH_SUBJECT = 'Action Needed: Please Submit a Corrected Document'
  SPANISH_SUBJECT = 'Acción requerida: envíe un documento corregido'

  ENGLISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Dear %<constituent_full_name>s,

    Thank you for submitting your %<proof_type_formatted>s for your MAT application. We reviewed it and need a corrected copy before we can continue processing your application.

    Reason we could not accept this document:
    %<rejection_reason>s
    %<additional_instructions>s

    %<remaining_attempts_message_text>s

    %<default_options_text>s

    %<archived_message_text>s

    %<footer_text>s
  TEXT

  SPANISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Estimado/a %<constituent_full_name>s,

    Gracias por enviar su %<proof_type_formatted>s para su solicitud de MAT. La revisamos y necesitamos una copia corregida antes de poder continuar con el trámite de su solicitud.

    Motivo por el que no pudimos aceptar este documento:
    %<rejection_reason>s
    %<additional_instructions>s

    %<remaining_attempts_message_text>s

    %<default_options_text>s

    %<archived_message_text>s

    %<footer_text>s
  TEXT

  VARIABLES = {
    'required' => %w[header_text constituent_full_name proof_type_formatted rejection_reason footer_text],
    'optional' => %w[organization_name secure_upload_url remaining_attempts_message_text additional_instructions default_options_text archived_message_text]
  }.freeze

  def up
    update_template!(
      locale: 'en',
      subject: ENGLISH_SUBJECT,
      description: 'Sent when a specific piece of documentation submitted by the applicant has been rejected.',
      body: ENGLISH_BODY
    )

    update_template!(
      locale: 'es',
      subject: SPANISH_SUBJECT,
      description: 'Enviado cuando se ha rechazado un documento específico enviado por el solicitante.',
      body: SPANISH_BODY
    )
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def update_template!(locale:, subject:, description:, body:)
    template = EmailTemplate.find_or_initialize_by(
      name: 'application_notifications_proof_rejected',
      format: :text,
      locale: locale
    )

    template.subject = subject
    template.description = description
    template.body = body
    template.variables = VARIABLES
    template.save!
  end
end
