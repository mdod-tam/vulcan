# frozen_string_literal: true

class CreateSecureRequestEmailTemplates < ActiveRecord::Migration[8.0]
  SHARED_TEMPLATES = {
    %w[email_header_text en] => {
      subject: 'Email Header Text',
      description: 'Standard text header used in all email templates',
      body: <<~TEXT,
        %<title>

        %<subtitle>
      TEXT
      variables: {
        'required' => %w[title],
        'optional' => %w[subtitle]
      }
    },
    %w[email_header_text es] => {
      subject: 'Texto de Encabezado de Correo Electrónico',
      description: 'Encabezado de texto estándar utilizado en todas las plantillas de correo electrónico',
      body: <<~TEXT,
        %<title>s

        %<subtitle>s
      TEXT
      variables: {
        'required' => %w[title],
        'optional' => %w[subtitle]
      }
    },
    %w[email_footer_text en] => {
      subject: 'Email Footer Text',
      description: 'Standard text footer used in all email templates',
      body: <<~TEXT,
        --
        %<organization_name>
        Email: %<contact_email>
        Website: %<website_url>

        %<show_automated_message>
        This is an automated message. Please do not reply directly to this email.
      TEXT
      variables: {
        'required' => %w[contact_email website_url],
        'optional' => %w[show_automated_message organization_name]
      }
    },
    %w[email_footer_text es] => {
      subject: 'Texto del Pie de Página del Correo Electrónico',
      description: 'Pie de página de texto estándar utilizado en todas las plantillas de correo electrónico',
      body: <<~TEXT,
        --
        %<organization_name>s
        Correo Electrónico: %<contact_email>s
        Sitio Web: %<website_url>s

        %<show_automated_message>s
        Este es un mensaje automático. Por favor, no responda directamente a este correo electrónico.
      TEXT
      variables: {
        'required' => %w[contact_email website_url],
        'optional' => %w[show_automated_message organization_name]
      }
    }
  }.freeze

  PROVIDER_INFO_TEMPLATES = {
    'en' => {
      subject: 'Certifying Professional Information Needed',
      description: 'Sent when MAT requests certifying professional contact information through a secure request form.',
      body: <<~TEXT
        %<header_text>s

        Dear %<user_first_name>s,

        The Maryland Accessible Telecommunications Program needs contact information for the certifying professional connected to %<constituent_name>s's application.

        %<provider_info_instructions>s

        We need the professional's name, phone number, email address, and fax number if available. Do not reply with medical records or other sensitive documents.

        If you have questions, contact our support team at %<support_email>s.

        %<footer_text>s
      TEXT
    },
    'es' => {
      subject: 'Se Necesita Información del Profesional Certificador',
      description: 'Enviado cuando MAT solicita información de contacto del profesional certificador mediante un formulario seguro.',
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<user_first_name>s,

        El Programa de Telecomunicaciones Accesibles de Maryland necesita información de contacto del profesional certificador relacionado con la solicitud de %<constituent_name>s.

        %<provider_info_instructions>s

        Necesitamos el nombre, número de teléfono, correo electrónico y número de fax del profesional, si está disponible. No responda con registros médicos u otros documentos sensibles.

        Si tiene preguntas, comuníquese con nuestro equipo de soporte en %<support_email>s.

        %<footer_text>s
      TEXT
    }
  }.freeze

  APPLICATION_SUBMITTED_TEMPLATES = {
    'en' => {
      subject: 'Your Application Has Been Submitted',
      description: 'Sent when an application is submitted.',
      body: <<~TEXT
        %<header_text>s

        Dear %<user_first_name>s,

        Thank you for submitting your application. We will review it as soon as possible.

        Application ID: %<application_id>s
        Submission Date: %<submission_date_formatted>s

        We will notify you of any status updates or if we need additional documentation.

        If you have any questions about your application, please contact our team at %<support_email>s or call (410) 767-6960.

        %<footer_text>s
      TEXT
    },
    'es' => {
      subject: 'Su Solicitud Ha Sido Enviada',
      description: 'Enviado cuando se envía una solicitud.',
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<user_first_name>s,

        Gracias por enviar su solicitud. La revisaremos lo antes posible.

        ID de Solicitud: %<application_id>s
        Fecha de Envío: %<submission_date_formatted>s

        Le notificaremos de cualquier actualización de estado o si necesitamos documentación adicional.

        Si tiene alguna pregunta sobre su solicitud, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

        %<footer_text>s
      TEXT
    }
  }.freeze

  MEDICAL_PROVIDER_REQUEST_TEMPLATES = {
    'en' => {
      subject: 'DISABILITY CERTIFICATION FORM REQUEST',
      description: 'Sent to a certifying professional requesting they complete and submit a disability certification form for an applicant.',
      body: <<~TEXT
        DISABILITY CERTIFICATION FORM REQUEST

        Hello,

        %<constituent_full_name>s recently applied to the Maryland Accessible Telecommunications Program for equipment that supports independent telephone use. They listed you as a professional who can certify that they have a disability.

        %<request_count_message>s

         INFORMATION:
        - Name: %<constituent_full_name>s
        - Date of Birth: %<constituent_dob_formatted>s
        - Phone: %<constituent_phone_formatted>s
        - Email: %<constituent_email>s
        - Address: %<constituent_address_formatted>s
        - Application ID: %<application_id>s

        To qualify for assistance through MAT, this applicant requires documentation that they have a disability that makes it difficult for them to use a standard telephone. The certification form is essential for this applicant to qualify for accessible telecommunications devices they need. To complete this form:

        %<certification_submission_instructions>s

        If you have questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

        Thank you for your prompt attention to this important matter.

        Sincerely,
        Maryland Accessible Telecommunications Program

        ---

        This email was sent regarding Application #%<application_id>s on behalf of %<constituent_full_name>s.
        CONFIDENTIALITY NOTICE: This email may contain confidential health information protected by state and federal privacy laws.
      TEXT
    },
    'es' => {
      subject: 'SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD',
      description: 'Enviado a un profesional certificador solicitándole que complete y envíe un formulario de certificación de discapacidad para un solicitante.',
      body: <<~TEXT
        SOLICITUD DE FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD

        Hola,

        Le escribimos para solicitarle que complete un formulario de certificación de discapacidad para este solicitante, %<constituent_full_name>s, quien está solicitando al Programa de Telecomunicaciones Accesibles de Maryland recibir equipos de telecomunicaciones accesibles para apoyar el uso independiente del teléfono.

        %<request_count_message>s

         INFORMACIÓN:
        - Nombre: %<constituent_full_name>s
        - Fecha de Nacimiento: %<constituent_dob_formatted>s
        - Teléfono: %<constituent_phone_formatted>s
        - Correo electrónico: %<constituent_email>s
        - Dirección: %<constituent_address_formatted>s
        - ID de Solicitud: %<application_id>s

        Para calificar para la asistencia a través de MAT, este solicitante requiere documentación de que tiene una discapacidad que le dificulta usar un teléfono estándar. El formulario de certificación es esencial para que este solicitante califique para los dispositivos de telecomunicaciones accesibles que necesita. Para completar este formulario:

        %<certification_submission_instructions>s

        Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

        Gracias por su pronta atención a este importante asunto.

        Atentamente,
        Programa de Telecomunicaciones Accesibles de Maryland

        ---

        Este correo electrónico fue enviado con respecto a la Solicitud #%<application_id>s en nombre de %<constituent_full_name>s.
        AVISO DE CONFIDENCIALIDAD: Este correo electrónico puede contener información de salud confidencial protegida por las leyes de privacidad estatales y federales.
      TEXT
    }
  }.freeze

  PROVIDER_INFO_VARIABLES = {
    'required' => %w[header_text user_first_name constituent_name provider_info_instructions support_email footer_text],
    'optional' => %w[secure_url expiration_hours application_id support_phone]
  }.freeze

  APPLICATION_SUBMITTED_VARIABLES = {
    'required' => %w[header_text user_first_name application_id submission_date_formatted footer_text support_email],
    'optional' => []
  }.freeze

  MEDICAL_PROVIDER_REQUEST_VARIABLES = {
    'required' => %w[constituent_full_name request_count_message constituent_dob_formatted constituent_phone_formatted constituent_email
                     constituent_address_formatted application_id certification_submission_instructions support_email],
    'optional' => %w[download_form_url secure_upload_url]
  }.freeze

  def up
    ensure_shared_templates
    ensure_medical_provider_request_templates
    upsert_provider_info_templates
    upsert_application_submitted_templates
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def ensure_shared_templates
    SHARED_TEMPLATES.each do |(name, locale), attributes|
      next if EmailTemplate.exists?(name: name, format: :text, locale: locale)

      EmailTemplate.create!(
        name: name,
        format: :text,
        locale: locale,
        version: 1,
        **attributes
      )
    end
  end

  def ensure_medical_provider_request_templates
    MEDICAL_PROVIDER_REQUEST_TEMPLATES.each do |locale, attributes|
      next if EmailTemplate.exists?(name: 'medical_provider_request_certification', format: :text, locale: locale)

      EmailTemplate.create!(
        name: 'medical_provider_request_certification',
        format: :text,
        locale: locale,
        version: 1,
        variables: MEDICAL_PROVIDER_REQUEST_VARIABLES,
        **attributes
      )
    end
  end

  def upsert_provider_info_templates
    PROVIDER_INFO_TEMPLATES.each do |locale, attributes|
      upsert_template!(
        name: 'application_notifications_provider_info_requested',
        locale: locale,
        attributes: attributes,
        version: 1,
        variables: PROVIDER_INFO_VARIABLES
      )
    end
  end

  def upsert_application_submitted_templates
    APPLICATION_SUBMITTED_TEMPLATES.each do |locale, attributes|
      upsert_template!(
        name: 'application_notifications_application_submitted',
        locale: locale,
        attributes: attributes,
        version: 1,
        variables: APPLICATION_SUBMITTED_VARIABLES
      )
    end
  end

  def upsert_template!(name:, locale:, attributes:, variables:, version:)
    template = EmailTemplate.find_or_initialize_by(name: name, format: :text, locale: locale)
    template.subject = attributes.fetch(:subject)
    template.description = attributes.fetch(:description)
    template.body = attributes.fetch(:body)
    template.variables = variables
    template.version = version if template.new_record?
    template.save!
  end
end
