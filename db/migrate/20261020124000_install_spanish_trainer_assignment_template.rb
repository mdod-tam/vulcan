# frozen_string_literal: true

class InstallSpanishTrainerAssignmentTemplate < ActiveRecord::Migration[8.1]
  class TemplateRecord < ActiveRecord::Base
    self.table_name = 'email_templates'
  end

  def up
    TemplateRecord.create_or_find_by!(name: 'training_session_notifications_trainer_assigned', format: 1, locale: 'es') do |template|
      template.assign_attributes(
        subject: 'Nueva asignación de capacitación',
        description: 'Enviado a un capacitador cuando se le ha asignado una sesión de capacitación.',
        body: <<~TEXT,
          %<header_text>s

          Hola %<trainer_full_name>s,

          Se le ha asignado como capacitador de %<constituent_full_name>s. Comuníquese con la persona para programar la primera sesión. Hay más información a continuación.

          Detalles de la persona:
          - Nombre: %<constituent_full_name>s
          - Correo electrónico: %<constituent_email>s
          - Teléfono: %<constituent_phone_formatted>s
          - Dirección: %<constituent_address_formatted>s
          - Discapacidades: %<constituent_disabilities_text_list>s

          Preferencias de comunicación:
          - Idioma preferido: %<constituent_language>s
          - Método de contacto preferido: %<constituent_contact_method>s
          - Modalidad de comunicación: %<constituent_communication_modality>s

          ID de solicitud: %<application_id>s

          %<footer_text>s
        TEXT
        variables: {
          'required' => %w[header_text trainer_full_name constituent_full_name constituent_email constituent_phone_formatted
                           constituent_address_formatted constituent_disabilities_text_list constituent_language constituent_contact_method
                           constituent_communication_modality application_id footer_text],
          'optional' => []
        }, version: 1, syntax: 0
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Trainer assignment templates may contain administrator edits.'
  end
end
