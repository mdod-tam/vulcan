# frozen_string_literal: true

# Seed File for "application_notifications_income_threshold_exceeded"
# (Suggest saving as db/seeds/email_templates/application_notifications_income_threshold_exceeded.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_income_threshold_exceeded', format: :text, locale: 'es') do |template|
  template.subject = 'Información Importante Sobre Su Solicitud MAT'
  template.description = 'Sent when an application is rejected because income exceeds the eligibility threshold.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<constituent_first_name>s,

    Hemos revisado su solicitud para el programa de Telecomunicaciones Accesibles de Maryland.

    SOLICITUD RECHAZADA

    Lamentablemente, no podemos aprobar su solicitud en este momento porque su ingreso anual reportado excede el límite de elegibilidad de nuestro programa.

    Tamaño de su hogar: %<household_size>s
    Ingreso anual reportado: %<annual_income_formatted>s
    Límite de ingresos máximo para el tamaño de su hogar: %<threshold_formatted>s

    %<additional_notes>s

    Si su situación financiera cambia, o si cree que esta determinación se tomó por error, puede enviar una nueva solicitud con información actualizada.

    Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text constituent_first_name annual_income_formatted household_size threshold_formatted footer_text support_email],
    'optional' => %w[additional_notes]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_income_threshold_exceeded_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
