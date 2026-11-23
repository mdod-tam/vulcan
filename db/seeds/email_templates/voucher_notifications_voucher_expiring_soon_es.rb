# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expiring_soon', format: :text, locale: 'es') do |template|
  template.subject = 'Importante: Su Vale Expirará Pronto'
  template.description = 'Enviado a la persona solicitante como recordatorio de que su vale se acerca a su fecha de vencimiento.'
  template.body = <<~TEXT
    Hola, %<vendor_business_name>s,

    Su vale vence el %<expiration_date_formatted>s. Le quedan %<remaining_value_formatted>s. El monto mínimo por compra es %<minimum_redemption_amount_formatted>s.

    Código del vale: %<voucher_code>s

    Si necesita ayuda, escriba a %<support_email>s o llame al 410-767-6960.
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name expiration_date_formatted remaining_value_formatted minimum_redemption_amount_formatted voucher_code support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expiring_soon_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
