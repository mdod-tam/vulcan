# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_redeemed"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_redeemed', format: :text, locale: 'es') do |template|
  template.subject = 'Vale Canjeado Exitosamente en Su Negocio'
  template.description = 'Enviado al proveedor cuando un constituyente canjea un vale en su negocio.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<vendor_business_name>s,

    Confirmamos que un vale ha sido canjeado exitosamente en su negocio por %<user_first_name>s.

    Detalles de la Transacción:
    - Código de Vale: %<voucher_code>s
    - Fecha de Transacción: %<transaction_date_formatted>s
    - Monto de Transacción: %<transaction_amount_formatted>s
    - Referencia de Transacción: %<transaction_reference_number>s
    - Fecha de Vencimiento: %<expiration_date_formatted>s

    Estado del Vale:
    - Valor Canjeado: %<redeemed_value_formatted>s
    - Saldo Restante: %<remaining_balance_formatted>s
    %<remaining_value_message_text>s
    %<fully_redeemed_message_text>s

    El pago de esta transacción se procesará de acuerdo con su acuerdo de proveedor. Puede ver todo su historial de transacciones en su portal de proveedor.

    Si tiene alguna pregunta sobre esta transacción, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[
      header_text vendor_business_name user_first_name voucher_code transaction_date_formatted
      transaction_amount_formatted transaction_reference_number expiration_date_formatted
      redeemed_value_formatted remaining_balance_formatted remaining_value_message_text
      fully_redeemed_message_text footer_text support_email
    ],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_redeemed_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
