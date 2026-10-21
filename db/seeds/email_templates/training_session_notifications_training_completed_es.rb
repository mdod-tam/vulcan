# frozen_string_literal: true

EmailTemplate.find_or_create_by!(name: 'training_session_notifications_training_completed', format: :text, locale: 'es') do |template|
  template.subject = 'Su informe de capacitación está listo'
  template.description = 'Se envía cuando el capacitador presenta un informe de capacitación completada.'
  template.body = <<~TEXT
    %<header_text>s

    Hola %<recipient_full_name>s:

    Su capacitación con %<trainer_full_name>s para %<constituent_full_name>s se completó el %<completed_date_formatted>s a las %<completed_time_formatted>s.

    %<report_access_text>s
    %<report_url>s

    El resumen conserva el idioma en el que lo escribió su capacitador.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text recipient_full_name constituent_full_name trainer_full_name
                     completed_date_formatted completed_time_formatted report_access_text report_url footer_text],
    'optional' => []
  }
  template.version = 1
end
