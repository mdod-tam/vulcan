# frozen_string_literal: true

class UpdateTrainerAssignedEmailTemplate < ActiveRecord::Migration[8.1]
  TEMPLATE_NAME = 'training_session_notifications_trainer_assigned'

  VARIABLES = {
    'required' => %w[
      header_text
      trainer_full_name
      constituent_full_name
      constituent_email
      constituent_phone_formatted
      constituent_address_formatted
      constituent_disabilities_text_list
      constituent_language
      constituent_contact_method
      constituent_communication_modality
      application_id
      footer_text
    ],
    'optional' => []
  }.freeze

  TEMPLATES = {
    'en' => {
      subject: 'New Training Assignment',
      description: 'Sent to a trainer when a training session has been assigned to them.',
      body: <<~TEXT
        %<header_text>s

        Hello %<trainer_full_name>s,

        You've been assigned as the trainer for %<constituent_full_name>s. Please contact them to schedule your first session. More information is below.

        Constituent details:
        - Name: %<constituent_full_name>s
        - Email: %<constituent_email>s
        - Phone: %<constituent_phone_formatted>s
        - Address: %<constituent_address_formatted>s
        - Disabilities: %<constituent_disabilities_text_list>s

        Communication preferences:
        - Preferred language: %<constituent_language>s
        - Preferred contact method: %<constituent_contact_method>s
        - Communication modality: %<constituent_communication_modality>s

        Application ID: %<application_id>s

        %<footer_text>s
      TEXT
    },
    'es' => {
      subject: 'Nueva asignación de capacitación',
      description: 'Enviado a un capacitador cuando se le ha asignado una sesión de capacitación.',
      body: <<~TEXT
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
    }
  }.freeze

  def up
    TEMPLATES.each do |locale, attrs|
      template = EmailTemplate.find_or_initialize_by(name: TEMPLATE_NAME, format: :text, locale: locale)
      template.update!(attrs.merge(variables: VARIABLES))
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
