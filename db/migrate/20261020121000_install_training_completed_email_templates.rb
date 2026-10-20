# frozen_string_literal: true

class InstallTrainingCompletedEmailTemplates < ActiveRecord::Migration[8.1]
  class TemplateRecord < ActiveRecord::Base
    self.table_name = 'email_templates'
  end

  VARIABLES = {
    'required' => %w[header_text recipient_full_name constituent_full_name trainer_full_name
                     completed_date_formatted completed_time_formatted report_url footer_text],
    'optional' => []
  }.freeze

  TEMPLATES = {
    'en' => {
      subject: 'Your training report is ready',
      description: 'Sent after a trainer submits a completed training report.',
      body: <<~TEXT
        %<header_text>s

        Hello %<recipient_full_name>s,

        Your training with %<trainer_full_name>s for %<constituent_full_name>s was completed on %<completed_date_formatted>s at %<completed_time_formatted>s.

        Sign in to read the written session summary and find guidance for the product used during training:
        %<report_url>s

        The summary keeps the language in which your trainer wrote it.

        %<footer_text>s
      TEXT
    },
    'es' => {
      subject: 'Su informe de capacitación está listo',
      description: 'Se envía cuando el capacitador presenta un informe de capacitación completada.',
      body: <<~TEXT
        %<header_text>s

        Hola %<recipient_full_name>s:

        Su capacitación con %<trainer_full_name>s para %<constituent_full_name>s se completó el %<completed_date_formatted>s a las %<completed_time_formatted>s.

        Inicie sesión para leer el resumen escrito de la sesión y encontrar orientación sobre el producto utilizado durante la capacitación:
        %<report_url>s

        El resumen conserva el idioma en el que lo escribió su capacitador.

        %<footer_text>s
      TEXT
    }
  }.freeze

  def up
    TEMPLATES.each do |locale, attributes|
      TemplateRecord.create_or_find_by!(name: 'training_session_notifications_training_completed', format: 1, locale: locale) do |template|
        template.assign_attributes(attributes.merge(variables: VARIABLES, version: 1, syntax: 0))
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Completion templates may contain administrator edits.'
  end
end
