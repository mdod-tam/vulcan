# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_expiring_soon"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_expiring_soon.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_expiring_soon', format: :text, locale: 'es') do |template|
  template.subject = 'Acción Requerida: Su Formulario W9 Caduca Pronto'
  template.description = 'Sent to a vendor as a warning that their W9 form on file is nearing its expiration date.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    %<status_box_warning_text>s

    Su formulario W9 caducará en %<days_until_expiry>s días el %<expiration_date_formatted>s.

    Para garantizar un servicio ininterrumpido y el procesamiento de pagos, envíe un formulario W9 actualizado antes de la fecha de vencimiento.

    CÓMO ENVIAR SU W9 ACTUALIZADO:
    1. Descargue el formulario W9 actual del sitio web del IRS: https://www.irs.gov/pub/irs-pdf/fw9.pdf
    2. Complete y firme el formulario
    3. Inicie sesión en su portal de proveedor en %<vendor_portal_url>s
    4. Vaya a "Perfil" y cargue su nuevo formulario W9

    Si ya ha enviado un formulario W9 actualizado, ignore este mensaje.

    %<status_box_info_text>s

    Si tiene alguna pregunta o necesita ayuda, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_warning_text days_until_expiry expiration_date_formatted vendor_portal_url status_box_info_text
                     footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_expiring_soon_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
