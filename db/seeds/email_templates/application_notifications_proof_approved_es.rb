# frozen_string_literal: true

# Seed File for "application_notifications_proof_approved"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_approved', format: :text, locale: 'es') do |template|
  template.subject = 'Actualización de Revisión de Documentos'
  template.description = 'Sent when a specific piece of documentation submitted by the applicant has been approved.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Hemos revisado y aprobado su documentación de %<proof_type_formatted>s.

    No se requiere ninguna otra acción en este momento.

    %<all_proofs_approved_message_text>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name proof_type_formatted footer_text],
    'optional' => %w[organization_name all_proofs_approved_message_text]
  }

  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_approved_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
