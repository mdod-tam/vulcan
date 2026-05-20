# frozen_string_literal: true

class CreateProofRequestedTemplates < ActiveRecord::Migration[8.0]
  ENGLISH_SUBJECT = 'Action Needed: Please Submit Your %<proof_type_formatted>s'
  SPANISH_SUBJECT = 'Acción requerida: envíe su %<proof_type_formatted>s'

  ENGLISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Dear %<constituent_full_name>s,

    We are reviewing your MAT application and still need your %<proof_type_formatted>s before we can continue processing your application.

    %<default_options_text>s

    %<footer_text>s
  TEXT

  SPANISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Estimado/a %<constituent_full_name>s,

    Estamos revisando su solicitud de MAT y todavía necesitamos su %<proof_type_formatted>s antes de poder continuar con el trámite de su solicitud.

    %<default_options_text>s

    %<footer_text>s
  TEXT

  VARIABLES = {
    'required' => %w[header_text constituent_full_name proof_type_formatted default_options_text footer_text],
    'optional' => %w[organization_name secure_upload_url]
  }.freeze

  def up
    upsert_template!(
      locale: 'en',
      subject: ENGLISH_SUBJECT,
      description: 'Sent when the program still needs a required proof document before any rejection has been issued.',
      body: ENGLISH_BODY
    )

    upsert_template!(
      locale: 'es',
      subject: SPANISH_SUBJECT,
      description: 'Se envía cuando el programa aún necesita un documento requerido antes de emitir un rechazo.',
      body: SPANISH_BODY
    )
  end

  def down
    EmailTemplate.where(name: 'application_notifications_proof_requested', format: :text, locale: %w[en es]).delete_all
  end

  private

  def upsert_template!(locale:, subject:, description:, body:)
    template = EmailTemplate.find_or_initialize_by(
      name: 'application_notifications_proof_requested',
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
