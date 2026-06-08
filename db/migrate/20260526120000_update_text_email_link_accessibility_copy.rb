# frozen_string_literal: true

class UpdateTextEmailLinkAccessibilityCopy < ActiveRecord::Migration[8.0]
  TEMPLATE_UPDATES = [
    {
      name: 'application_notifications_account_created',
      locale: 'en',
      subject: 'We Received Your Maryland Accessible Telecommunications Application',
      description: 'Sent when an application is received and a constituent account is created.',
      variables: { 'required' => %w[header_text constituent_first_name support_email program_website_url footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Dear %<constituent_first_name>s,

        We have received your application for accessible telecommunications equipment and services.

        We will send you important updates and documents regarding your application status as we review it.

        If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

        MAT program website:
        %<program_website_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_account_created',
      locale: 'es',
      subject: 'Recibimos su solicitud de Telecomunicaciones Accesibles de Maryland',
      description: 'Enviado cuando se recibe una solicitud y se crea una cuenta de constituyente.',
      variables: { 'required' => %w[header_text constituent_first_name support_email program_website_url footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<constituent_first_name>s,

        Hemos recibido su solicitud de equipos y servicios de telecomunicaciones accesibles.

        Le enviaremos actualizaciones importantes y documentos sobre el estado de su solicitud mientras la revisamos.

        Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s o llame al (410) 767-6960.

        Sitio web del programa MAT:
        %<program_website_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_proof_needs_review_reminder',
      locale: 'en',
      subject: 'Applications Awaiting Review',
      description: 'Sent to administrators summarizing applications that have been awaiting review for too long (e.g., > 3 days).',
      variables: { 'required' => %w[header_text admin_full_name stale_reviews_count stale_reviews_text_list admin_dashboard_url footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Dear %<admin_full_name>s,

        ==================================================
        ! ATTENTION REQUIRED
        ==================================================

        There are %<stale_reviews_count>s applications that have been awaiting document review for more than 3 days.

        APPLICATIONS REQUIRING ATTENTION
        %<stale_reviews_text_list>s

        Please review these applications as soon as possible to ensure timely processing for our applicants.

        Admin dashboard link:
        %<admin_dashboard_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_proof_needs_review_reminder',
      locale: 'es',
      subject: 'Solicitudes Pendientes de Revisión',
      description: 'Enviado a los administradores resumiendo las solicitudes que han estado esperando revisión durante demasiado tiempo (por ejemplo, > 3 días).',
      variables: { 'required' => %w[header_text admin_full_name stale_reviews_count stale_reviews_text_list admin_dashboard_url footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<admin_full_name>s,

        ==================================================
        ! ATENCIÓN REQUERIDA
        ==================================================

        Hay %<stale_reviews_count>s solicitudes que han estado esperando revisión de documentos por más de 3 días.

        SOLICITUDES QUE REQUIEREN ATENCIÓN
        %<stale_reviews_text_list>s

        Por favor, revise estas solicitudes lo antes posible para asegurar un procesamiento oportuno para nuestros solicitantes.

        Enlace al panel de administrador:
        %<admin_dashboard_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_security_key_recovery_approved',
      locale: 'en',
      subject: 'Security Key Recovery Approved',
      description: 'Sent when an administrator approves a security key recovery request.',
      variables: { 'required' => %w[header_text user_first_name sign_in_url support_email footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Dear %<user_first_name>s,

        Your security key recovery request has been approved. Your existing security keys have been removed from your account.

        Please sign in and register a new security key.

        Sign-in link:
        %<sign_in_url>s

        If you have questions or need assistance, please contact our team at %<support_email>s.

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_security_key_recovery_approved',
      locale: 'es',
      subject: 'Recuperación de Llave de Seguridad Aprobada',
      description: 'Enviado cuando un administrador aprueba una solicitud de recuperación de llave de seguridad.',
      variables: { 'required' => %w[header_text user_first_name sign_in_url support_email footer_text], 'optional' => [] },
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<user_first_name>s,

        Su solicitud de recuperación de llave de seguridad ha sido aprobada. Sus llaves de seguridad existentes se han eliminado de su cuenta.

        Inicie sesión y registre una nueva llave de seguridad.

        Enlace de inicio de sesión:
        %<sign_in_url>s

        Si tiene preguntas o necesita ayuda, comuníquese con nuestro equipo a %<support_email>s.

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_training_requested',
      locale: 'en',
      subject: 'Training Requested for Application #%<application_id>s',
      description: 'Sent to administrators when a constituent requests training.',
      variables: {
        'required' => %w[header_text admin_full_name constituent_full_name application_id request_date_formatted
                         admin_application_url footer_text],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Hello %<admin_full_name>s,

        %<constituent_full_name>s requested training for Application #%<application_id>s on %<request_date_formatted>s.

        Admin application link:
        %<admin_application_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'application_notifications_training_requested',
      locale: 'es',
      subject: 'Capacitación solicitada para la solicitud #%<application_id>s',
      description: 'Se envía a administradores cuando un constituyente solicita capacitación.',
      variables: {
        'required' => %w[header_text admin_full_name constituent_full_name application_id request_date_formatted
                         admin_application_url footer_text],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Hola %<admin_full_name>s,

        %<constituent_full_name>s solicitó capacitación para la solicitud #%<application_id>s el %<request_date_formatted>s.

        Enlace a la solicitud administrativa:
        %<admin_application_url>s

        %<footer_text>s
      TEXT
    },
    {
      name: 'email_footer_text',
      locale: 'en',
      subject: 'Email Footer Text',
      description: 'Standard text footer used in all email templates',
      variables: { 'required' => %w[contact_email website_url], 'optional' => %w[show_automated_message organization_name] },
      body: <<~TEXT
        --
        %<organization_name>
        Email: %<contact_email>
        MAT program website:
        %<website_url>s

        %<show_automated_message>
        This is an automated message. Please do not reply directly to this email.
      TEXT
    },
    {
      name: 'email_footer_text',
      locale: 'es',
      subject: 'Texto del Pie de Página del Correo Electrónico',
      description: 'Pie de página de texto estándar utilizado en todas las plantillas de correo electrónico',
      variables: { 'required' => %w[contact_email website_url], 'optional' => %w[show_automated_message organization_name] },
      body: <<~TEXT
        --
        %<organization_name>s
        Correo Electrónico: %<contact_email>s
        Sitio web del programa MAT:
        %<website_url>s

        %<show_automated_message>s
        Este es un mensaje automático. Por favor, no responda directamente a este correo electrónico.
      TEXT
    },
    {
      name: 'evaluator_mailer_new_evaluation_assigned',
      locale: 'en',
      subject: 'New Evaluation Assigned',
      description: 'Sent to an evaluator when a new constituent evaluation has been assigned to them.',
      variables: {
        'required' => %w[header_text evaluator_full_name status_box_text constituent_full_name
                         constituent_address_formatted constituent_phone_formatted constituent_email
                         constituent_disabilities_text_list evaluators_evaluation_url footer_text],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Hi %<evaluator_full_name>s,

        %<status_box_text>s

        CONSTITUENT DETAILS:
        - Name: %<constituent_full_name>s
        - Address: %<constituent_address_formatted>s
        - Phone: %<constituent_phone_formatted>s
        - Email: %<constituent_email>s

        DISABILITIES:
        %<constituent_disabilities_text_list>s

        Evaluator evaluation link:
        %<evaluators_evaluation_url>s

        Please begin the evaluation process by contacting the constituent to schedule an assessment.

        %<footer_text>s
      TEXT
    },
    {
      name: 'evaluator_mailer_new_evaluation_assigned',
      locale: 'es',
      subject: 'Nueva Evaluación Asignada',
      description: 'Enviado a un evaluador cuando se le ha asignado una nueva evaluación de un constituyente.',
      variables: {
        'required' => %w[header_text evaluator_full_name status_box_text constituent_full_name
                         constituent_address_formatted constituent_phone_formatted constituent_email
                         constituent_disabilities_text_list evaluators_evaluation_url footer_text],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Hola %<evaluator_full_name>s,

        %<status_box_text>s

        DETALLES DEL SOLICITANTE:
        - Nombre: %<constituent_full_name>s
        - Dirección: %<constituent_address_formatted>s
        - Teléfono: %<constituent_phone_formatted>s
        - Correo Electrónico: %<constituent_email>s

        DISCAPACIDADES:
        %<constituent_disabilities_text_list>s

        Enlace de evaluación para evaluador:
        %<evaluators_evaluation_url>s

        Por favor, comience el proceso de evaluación comunicándose con el solicitante para programar una evaluación.

        %<footer_text>s
      TEXT
    },
    {
      name: 'medical_provider_certification_rejected',
      locale: 'en',
      subject: 'Disability Certification Rejected',
      description: 'Sent to a medical provider when the submitted disability certification form is rejected.',
      variables: { 'required' => %w[constituent_full_name application_id rejection_reason certification_resubmission_instructions], 'optional' => [] },
      body: <<~TEXT
        MARYLAND ACCESSIBLE TELECOMMUNICATIONS

        DISABILITY CERTIFICATION FORM REJECTED

        Hello,

        We have received the disability certification form for the following individual:

        Name: %<constituent_full_name>s
        Application ID: %<application_id>s

        Unfortunately, the certification form has been rejected due to the following reason:

        %<rejection_reason>s

        NEXT STEPS

        Please submit a new disability certification form using one of the following methods:

        %<certification_resubmission_instructions>s

        Thank you for your assistance in helping the applicant access needed telecommunications services.

        Sincerely,
        Maryland Accessible Telecommunications Program

        ----------

        For questions, please contact us at mat.program1@maryland.gov or call 410-767-6960.
        Maryland Accessible Telecommunications (MAT) - Improving lives through accessible communication.
      TEXT
    },
    {
      name: 'medical_provider_certification_rejected',
      locale: 'es',
      subject: 'Certificación de Discapacidad Rechazada',
      description: 'Enviado a un proveedor médico cuando se rechaza el formulario de certificación de discapacidad enviado.',
      variables: { 'required' => %w[constituent_full_name application_id rejection_reason certification_resubmission_instructions], 'optional' => [] },
      body: <<~TEXT
        TELECOMUNICACIONES ACCESIBLES DE MARYLAND

        FORMULARIO DE CERTIFICACIÓN DE DISCAPACIDAD RECHAZADO

        Hola,

        Hemos recibido el formulario de certificación de discapacidad para la siguiente persona:

        Nombre: %<constituent_full_name>s
        ID de Solicitud: %<application_id>s

        Lamentablemente, el formulario de certificación ha sido rechazado por el siguiente motivo:

        %<rejection_reason>s

        PRÓXIMOS PASOS

        Por favor envíe un nuevo formulario de certificación de discapacidad utilizando uno de los siguientes métodos:

        %<certification_resubmission_instructions>s

        Gracias por su ayuda para que este solicitante acceda a los servicios de telecomunicaciones que necesita.

        Atentamente,
        Programa de Telecomunicaciones Accesibles de Maryland

        ----------

        Para preguntas, comuníquese con nosotros a mat.program1@maryland.gov o llame al 410-767-6960.
        Telecomunicaciones Accesibles de Maryland (MAT) - Mejorando vidas a través de la comunicación accesible.
      TEXT
    },
    {
      name: 'user_mailer_email_verification',
      locale: 'en',
      subject: 'Please confirm your email address',
      description: 'Sent to a user to verify their email address using the verification link.',
      variables: { 'required' => %w[user_email verification_url], 'optional' => [] },
      body: <<~TEXT
        Hey there,

        This is to confirm that %<user_email>s is the email you've chosen use on your account. If you ever lose your password, that's where we'll email a reset link.

        Use the email verification link to confirm that you received this email.

        Email verification link:
        %<verification_url>s

        ---

        Have questions or need help? Just reply to this email and our team will help you sort it out.
      TEXT
    },
    {
      name: 'user_mailer_email_verification',
      locale: 'es',
      subject: 'Por favor confirme su dirección de correo electrónico',
      description: 'Enviado a un usuario para verificar su dirección de correo electrónico usando el enlace de verificación.',
      variables: { 'required' => %w[user_email verification_url], 'optional' => [] },
      body: <<~TEXT
        Hola,

        Esto es para confirmar que %<user_email>s es el correo electrónico que ha elegido usar en su cuenta. Si alguna vez pierde su contraseña, ahí es donde enviaremos un enlace de restablecimiento.

        Use el enlace de verificación de correo electrónico para confirmar que recibió este correo electrónico.

        Enlace de verificación de correo electrónico:
        %<verification_url>s

        ---

        ¿Tiene preguntas o necesita ayuda? Simplemente responda a este correo electrónico y nuestro equipo le ayudará a resolverlo.
      TEXT
    },
    {
      name: 'user_mailer_password_reset',
      locale: 'en',
      subject: 'Account Access Instructions',
      description: 'Sent when a user requests account access or a password reset. Contains a link to set a password.',
      variables: { 'required' => %w[user_email reset_url], 'optional' => [] },
      body: <<~TEXT
        Hello,

        We received a request for account access or a password reset for %<user_email>s.

        Use the password reset link to set your password and access your account.

        Password reset link:
        %<reset_url>s

        This link expires in 20 minutes. If you did not request account access, you can safely ignore this email.

        ---

        Have questions or need help? Reply to this email and our support team will help.
      TEXT
    },
    {
      name: 'user_mailer_password_reset',
      locale: 'es',
      subject: 'Instrucciones de acceso a la cuenta',
      description: 'Enviado cuando un usuario solicita acceso a la cuenta o restablecer su contraseña. Contiene un enlace para establecer una contraseña.',
      variables: { 'required' => %w[user_email reset_url], 'optional' => [] },
      body: <<~TEXT
        Hola,

        Recibimos una solicitud de acceso a la cuenta o de restablecimiento de contraseña para %<user_email>s.

        Use el enlace de restablecimiento de contraseña para establecer su contraseña y acceder a su cuenta.

        Enlace de restablecimiento de contraseña:
        %<reset_url>s

        Este enlace caduca en 20 minutos. Si no solicitó acceso a la cuenta, puede ignorar este correo electrónico.

        ---

        ¿Tiene preguntas o necesita ayuda? Responda a este correo electrónico y nuestro equipo de soporte le ayudará.
      TEXT
    },
    {
      name: 'vendor_notifications_w9_expired',
      locale: 'en',
      subject: 'W9 Form Has Expired',
      description: 'Sent to a vendor when their W9 form on file has expired, requiring them to upload a new one to continue receiving payments.',
      variables: {
        'required' => %w[header_text vendor_business_name status_box_error_text status_box_warning_text
                         expiration_date_formatted status_box_info_text vendor_portal_url footer_text support_email],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Dear %<vendor_business_name>s,

        %<status_box_error_text>s
        %<status_box_warning_text>s

        Your W9 form expired on %<expiration_date_formatted>s.

        To resume payment processing for voucher transactions, please submit an updated W9 form as soon as possible.

        HOW TO SUBMIT YOUR UPDATED W9:
        1. IRS W-9 PDF:
           https://www.irs.gov/pub/irs-pdf/fw9.pdf
        2. Complete and sign the form
        3. Vendor portal link:
           %<vendor_portal_url>s
        4. Navigate to "Profile" and upload your new W9 form

        %<status_box_info_text>s

        If you have already submitted an updated W9 form, please disregard this message.

        If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

        %<footer_text>s
      TEXT
    },
    {
      name: 'vendor_notifications_w9_expired',
      locale: 'es',
      subject: 'El Formulario W9 ha Expirado',
      description: 'Enviado a un proveedor cuando su formulario W9 archivado ha caducado, requiriendo que suba uno nuevo para continuar recibiendo pagos.',
      variables: {
        'required' => %w[header_text vendor_business_name status_box_error_text status_box_warning_text
                         expiration_date_formatted status_box_info_text vendor_portal_url footer_text support_email],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<vendor_business_name>s,

        %<status_box_error_text>s
        %<status_box_warning_text>s

        Su formulario W9 expiró el %<expiration_date_formatted>s.

        Para reanudar el procesamiento de pagos por transacciones de vales, envíe un formulario W9 actualizado lo antes posible.

        CÓMO ENVIAR SU W9 ACTUALIZADO:
        1. PDF W-9 del IRS:
           https://www.irs.gov/pub/irs-pdf/fw9.pdf
        2. Complete y firme el formulario
        3. Enlace al portal de proveedor:
           %<vendor_portal_url>s
        4. Vaya a "Perfil" y cargue su nuevo formulario W9

        %<status_box_info_text>s

        Si ya ha enviado un formulario W9 actualizado, ignore este mensaje.

        Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

        %<footer_text>s
      TEXT
    },
    {
      name: 'vendor_notifications_w9_expiring_soon',
      locale: 'en',
      subject: 'Action Required: Your W9 Form is Expiring Soon',
      description: 'Sent to a vendor as a warning that their W9 form on file is nearing its expiration date.',
      variables: {
        'required' => %w[header_text vendor_business_name status_box_warning_text days_until_expiry
                         expiration_date_formatted vendor_portal_url status_box_info_text footer_text support_email],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Dear %<vendor_business_name>s,

        %<status_box_warning_text>s

        Your W9 form will expire in %<days_until_expiry>s days on %<expiration_date_formatted>s.

        To ensure uninterrupted service and payment processing, please submit an updated W9 form before the expiration date.

        HOW TO SUBMIT YOUR UPDATED W9:
        1. IRS W-9 PDF:
           https://www.irs.gov/pub/irs-pdf/fw9.pdf
        2. Complete and sign the form
        3. Vendor portal link:
           %<vendor_portal_url>s
        4. Navigate to "Profile" and upload your new W9 form

        If you have already submitted an updated W9 form, please disregard this message.

        %<status_box_info_text>s

        If you have any questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

        %<footer_text>s
      TEXT
    },
    {
      name: 'vendor_notifications_w9_expiring_soon',
      locale: 'es',
      subject: 'Acción Requerida: Su Formulario W9 Caduca Pronto',
      description: 'Enviado a un proveedor como advertencia de que su formulario W9 archivado se acerca a su fecha de vencimiento.',
      variables: {
        'required' => %w[header_text vendor_business_name status_box_warning_text days_until_expiry
                         expiration_date_formatted vendor_portal_url status_box_info_text footer_text support_email],
        'optional' => []
      },
      body: <<~TEXT
        %<header_text>s

        Estimado/a %<vendor_business_name>s,

        %<status_box_warning_text>s

        Su formulario W9 caducará en %<days_until_expiry>s días el %<expiration_date_formatted>s.

        Para garantizar un servicio ininterrumpido y el procesamiento de pagos, envíe un formulario W9 actualizado antes de la fecha de vencimiento.

        CÓMO ENVIAR SU W9 ACTUALIZADO:
        1. PDF W-9 del IRS:
           https://www.irs.gov/pub/irs-pdf/fw9.pdf
        2. Complete y firme el formulario
        3. Enlace al portal de proveedor:
           %<vendor_portal_url>s
        4. Vaya a "Perfil" y cargue su nuevo formulario W9

        Si ya ha enviado un formulario W9 actualizado, ignore este mensaje.

        %<status_box_info_text>s

        Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

        %<footer_text>s
      TEXT
    }
  ].freeze

  def up
    TEMPLATE_UPDATES.each do |attributes|
      update_template!(attributes)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def update_template!(attributes)
    template = EmailTemplate.find_or_initialize_by(
      name: attributes.fetch(:name),
      format: :text,
      locale: attributes.fetch(:locale)
    )

    template.update!(
      subject: attributes.fetch(:subject),
      description: attributes.fetch(:description),
      body: attributes.fetch(:body),
      variables: attributes.fetch(:variables),
      needs_sync: false
    )
  end
end
