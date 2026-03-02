# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_expired"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_expired.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_expired', format: :text, locale: 'es') do |template|
  template.subject = 'El Formulario W9 ha Expirado'
  template.description = 'Sent to a vendor when their W9 form on file has expired, requiring them to upload a new one to continue receiving payments.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    %<status_box_error_text>s
    %<status_box_warning_text>s

    Su formulario W9 expiró el %<expiration_date_formatted>s.

    Para reanudar el procesamiento de pagos por transacciones de vales, envíe un formulario W9 actualizado lo antes posible.

    CÓMO ENVIAR SU W9 ACTUALIZADO:
    1. Descargue el formulario W9 actual del sitio web del IRS: https://www.irs.gov/pub/irs-pdf/fw9.pdf
    2. Complete y firme el formulario
    3. Inicie sesión en su portal de proveedor en %<vendor_portal_url>s
    4. Vaya a "Perfil" y cargue su nuevo formulario W9

    %<status_box_info_text>s

    Si ya ha enviado un formulario W9 actualizado, ignore este mensaje.

    Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_error_text status_box_warning_text expiration_date_formatted status_box_info_text vendor_portal_url
                     footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_expired_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
