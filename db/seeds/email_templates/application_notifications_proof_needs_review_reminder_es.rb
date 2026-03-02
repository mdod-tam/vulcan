# frozen_string_literal: true

# Seed File for "application_notifications_proof_needs_review_reminder"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_proof_needs_review_reminder', format: :text, locale: 'es') do |template|
  template.subject = 'Solicitudes Pendientes de Revisión'
  template.description = 'Sent to administrators summarizing applications that have been awaiting review for too long (e.g., > 3 days).'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<admin_full_name>s,

    ==================================================
    ! ATENCIÓN REQUERIDA
    ==================================================

    Hay %<stale_reviews_count>s solicitudes que han estado esperando revisión de documentos por más de 3 días.

    SOLICITUDES QUE REQUIEREN ATENCIÓN
    %<stale_reviews_text_list>s

    Por favor, revise estas solicitudes lo antes posible para asegurar un procesamiento oportuno para nuestros solicitantes.

    Puede acceder al panel de control de administrador para revisar todas las solicitudes pendientes en:
    %<admin_dashboard_url>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text admin_full_name stale_reviews_count stale_reviews_text_list
                     admin_dashboard_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_proof_needs_review_reminder_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
