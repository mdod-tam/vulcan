# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_expiring_soon"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expiring_soon', format: :text, locale: 'es') do |template|
  template.subject = 'Importante: Su Vale Expirará Pronto'
  template.description = 'Enviado al proveedor como recordatorio de que su vale se acerca a su fecha de vencimiento.'
  template.body = <<~TEXT
    Importante: Su Vale Expirará Pronto

    Estimado/a %<vendor_business_name>s,

    Este es un recordatorio de que su vale expirará en %<days_until_expiry>s días el %<expiration_date_formatted>s.

    %<status_box_warning_text>s
    %<status_box_info_text>s

    Detalles del Vale:
    - Código de Vale: %<voucher_code>s
    - Valor Restante: %<remaining_value_formatted>s
    - Fecha de Vencimiento: %<expiration_date_formatted>s

    Recordatorios Importantes:
    * Cualquier valor no utilizado se perderá después de la fecha de vencimiento
    * El monto mínimo de canje es %<minimum_redemption_amount_formatted>s
    * Contáctenos de inmediato si tiene algún problema al usar su vale

    Para asegurarse de no perder el valor de su vale, haga arreglos para usarlo antes de la fecha de vencimiento.

    Si necesita ayuda o tiene alguna pregunta, no dude en contactarnos.

    Atentamente,
    El Equipo del Programa MAT
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name days_until_expiry expiration_date_formatted status_box_warning_text
                     status_box_info_text voucher_code remaining_value_formatted minimum_redemption_amount_formatted],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expiring_soon_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
