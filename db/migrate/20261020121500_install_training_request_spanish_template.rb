# frozen_string_literal: true

class InstallTrainingRequestSpanishTemplate < ActiveRecord::Migration[8.1]
  class TemplateRecord < ActiveRecord::Base
    self.table_name = 'email_templates'
  end

  def up
    TemplateRecord.create_or_find_by!(name: 'application_notifications_training_requested', format: 1, locale: 'es') do |template|
      template.assign_attributes(
        subject: 'Capacitación solicitada para la solicitud #%<application_id>s',
        description: 'Se envía al capacitador asignado cuando la persona solicita capacitación.',
        body: <<~TEXT,
          %<header_text>s

          Hola %<admin_full_name>s:

          %<constituent_full_name>s solicitó capacitación para la solicitud #%<application_id>s el %<request_date_formatted>s.

          Enlace a la solicitud de capacitación:
          %<admin_application_url>s

          %<footer_text>s
        TEXT
        variables: {
          'required' => %w[header_text admin_full_name constituent_full_name application_id request_date_formatted admin_application_url footer_text],
          'optional' => []
        }, version: 1, syntax: 0
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Training request templates may contain administrator edits.'
  end
end
