# frozen_string_literal: true

class UpdateVendorW9RejectedTemplatesForSecureUpload < ActiveRecord::Migration[8.0]
  ENGLISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Dear %<vendor_business_name>s,

    We have reviewed your submitted W9 form and found that it requires some corrections before we can proceed.

    %<status_box_text>s

    Reason for Rejection:
    %<rejection_reason>s

    Next Steps:
    %<w9_resubmission_instructions>s

    Once you've submitted a corrected W9 form, our team will review it promptly.

    If you have any questions or need assistance, please don't hesitate to contact our team at %<support_email>s or call (410) 767-6960.

    Thank you for your cooperation.

    %<footer_text>s
  TEXT

  SPANISH_BODY = <<~TEXT.freeze
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    Hemos revisado su formulario W9 enviado y hemos encontrado que requiere algunas correcciones antes de que podamos continuar.

    %<status_box_text>s

    Motivo del Rechazo:
    %<rejection_reason>s

    Próximos Pasos:
    %<w9_resubmission_instructions>s

    Una vez que haya enviado un formulario W9 corregido, nuestro equipo lo revisará de inmediato.

    Si tiene alguna pregunta o necesita ayuda, no dude en comunicarse con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    Gracias por su cooperación.

    %<footer_text>s
  TEXT

  VARIABLES = {
    'required' => %w[header_text vendor_business_name status_box_text rejection_reason w9_resubmission_instructions footer_text support_email],
    'optional' => %w[secure_upload_url vendor_portal_url]
  }.freeze

  def up
    update_template!(
      locale: 'en',
      subject: 'W9 Form Requires Correction',
      description: 'Sent to a vendor when their submitted W9 form has been rejected and requires corrections.',
      body: ENGLISH_BODY
    )

    update_template!(
      locale: 'es',
      subject: 'El Formulario W9 Requiere Corrección',
      description: 'Enviado a un proveedor cuando su formulario W9 enviado ha sido rechazado y requiere correcciones.',
      body: SPANISH_BODY
    )
  end

  def down
    # Intentionally no-op. We do not want to restore the stale vendor-portal-only copy.
  end

  private

  def update_template!(locale:, subject:, description:, body:)
    template = EmailTemplate.find_or_initialize_by(name: 'vendor_notifications_w9_rejected', format: :text, locale: locale)
    template.subject = subject
    template.description = description
    template.body = body
    template.variables = VARIABLES
    template.version = 2
    template.save!
  end
end
