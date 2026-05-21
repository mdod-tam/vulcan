# frozen_string_literal: true

class UpdateAccountCreatedAndContactTemplates < ActiveRecord::Migration[8.0]
  ACCOUNT_CREATED_BODIES = {
    'en' => <<~TEXT,
      %<header_text>s

      Dear %<constituent_first_name>s,

      We have received your application for accessible telecommunications equipment and services.

      We will send you important updates and documents regarding your application status as we review it.

      If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

      Program website: %<program_website_url>s

      %<footer_text>s
    TEXT
    'es' => <<~TEXT
      %<header_text>s

      Estimado/a %<constituent_first_name>s,

      Hemos recibido su solicitud de equipos y servicios de telecomunicaciones accesibles.

      Le enviaremos actualizaciones importantes y documentos sobre el estado de su solicitud mientras la revisamos.

      Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

      Sitio web del programa: %<program_website_url>s

      %<footer_text>s
    TEXT
  }.freeze

  ACCOUNT_CREATED_SUBJECTS = {
    'en' => 'We Received Your Maryland Accessible Telecommunications Application',
    'es' => 'Recibimos su solicitud de Telecomunicaciones Accesibles de Maryland'
  }.freeze

  RECOVERY_BODIES = {
    'en' => <<~TEXT,
      %<header_text>s

      Dear %<user_first_name>s,

      Your security key recovery request has been approved. Your existing security keys have been removed from your account.

      Please sign in and register a new security key: %<sign_in_url>s

      If you have questions or need assistance, please contact our team at %<support_email>s.

      %<footer_text>s
    TEXT
    'es' => <<~TEXT
      %<header_text>s

      Estimado/a %<user_first_name>s,

      Su solicitud de recuperación de llave de seguridad ha sido aprobada. Sus llaves de seguridad existentes se han eliminado de su cuenta.

      Inicie sesión y registre una nueva llave de seguridad: %<sign_in_url>s

      Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s.

      %<footer_text>s
    TEXT
  }.freeze

  RECOVERY_SUBJECTS = {
    'en' => 'Security Key Recovery Approved',
    'es' => 'Recuperación de Llave de Seguridad Aprobada'
  }.freeze

  def up
    update_account_created_templates
    upsert_security_key_recovery_templates
    normalize_old_office_address
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def update_account_created_templates
    ACCOUNT_CREATED_BODIES.each do |locale, body|
      template = EmailTemplate.find_or_initialize_by(
        name: 'application_notifications_account_created',
        format: :text,
        locale: locale
      )
      template.update!(
        subject: ACCOUNT_CREATED_SUBJECTS.fetch(locale),
        description: account_created_description(locale),
        body: body,
        variables: {
          'required' => %w[header_text constituent_first_name support_email program_website_url footer_text],
          'optional' => []
        }
      )
    end
  end

  def upsert_security_key_recovery_templates
    RECOVERY_BODIES.each do |locale, body|
      template = EmailTemplate.find_or_initialize_by(
        name: 'application_notifications_security_key_recovery_approved',
        format: :text,
        locale: locale
      )
      template.update!(
        subject: RECOVERY_SUBJECTS.fetch(locale),
        description: recovery_description(locale),
        body: body,
        variables: {
          'required' => %w[header_text user_first_name sign_in_url support_email footer_text],
          'optional' => []
        }
      )
    end
  end

  def normalize_old_office_address
    EmailTemplate.find_each do |template|
      body = template.body.to_s
      normalized_body = body
                        .gsub(/Maryland Accessible Telecommunications\s+123 Main Street\s+Baltimore, MD 21201/,
                              "Maryland Accessible Telecommunications\n%<office_address>s")
                        .gsub(/Telecomunicaciones Accesibles de Maryland\s+123 Main Street\s+Baltimore, MD 21201/,
                              "Telecomunicaciones Accesibles de Maryland\n%<office_address>s")
                        .gsub('123 Main Street, Baltimore, MD 21201', '%<office_address>s')
      next if normalized_body == body

      template.variables = variables_with_office_address(template.variables)
      template.body = normalized_body
      template.save!
    end
  end

  def variables_with_office_address(variables)
    normalized = (variables.presence || {}).deep_dup
    normalized['required'] ||= []
    normalized['optional'] ||= []
    normalized['optional'] |= ['office_address']
    normalized
  end

  def account_created_description(locale)
    if locale == 'es'
      'Enviado cuando se recibe una solicitud y se crea una cuenta de constituyente.'
    else
      'Sent when an application is received and a constituent account is created.'
    end
  end

  def recovery_description(locale)
    if locale == 'es'
      'Enviado cuando un administrador aprueba una solicitud de recuperación de llave de seguridad.'
    else
      'Sent when an administrator approves a security key recovery request.'
    end
  end
end
