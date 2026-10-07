# frozen_string_literal: true

# Seed File for "voucher_notifications_shipment_tracking_added"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_shipment_tracking_added', format: :text, locale: 'es') do |template|
  template.subject = 'Un paquete de %<vendor_business_name>s está en camino'
  template.description = 'Enviado al solicitante, o al tutor que administra la solicitud, cuando un proveedor registra el rastreo de un paquete.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s:

    %<vendor_business_name>s ha enviado un paquete de su compra con vale del %<transaction_date_formatted>s.

    Número de rastreo: %<tracking_number>s

    Su pedido puede llegar en más de un paquete. Todos los paquetes registrados para esta compra aparecen en su cuenta.

    Página de pedidos y envíos:
    %<orders_url>s

    Si tiene preguntas sobre su pedido, comuníquese con %<vendor_business_name>s o con nuestro equipo en %<support_email>s o al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name vendor_business_name transaction_date_formatted tracking_number orders_url support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_shipment_tracking_added (es text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
