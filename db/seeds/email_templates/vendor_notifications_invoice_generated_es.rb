# frozen_string_literal: true

# Seed File for "vendor_notifications_invoice_generated"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_invoice_generated.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_invoice_generated', format: :text, locale: 'es') do |template|
  template.subject = 'Nueva Factura Generada'
  template.description = 'Sent to a vendor when a new invoice has been generated based on their recent voucher transactions.'
  template.body = <<~TEXT
    Nueva Factura Generada

    Estimado/a %<vendor_business_name>s,

    Se ha generado una nueva factura por sus transacciones de vales recientes.

    DETALLES DE LA FACTURA
    --------------
    Número de Factura: %<invoice_number>s
    Período: %<period_start_formatted>s - %<period_end_formatted>s
    Monto Total: %<total_amount_formatted>s

    RESUMEN DE TRANSACCIONES
    -----------------
    %<transactions_text_list>s

    PRÓXIMOS PASOS
    ---------
    Nuestro equipo de contabilidad revisará esta factura y procesará el pago dentro de los 30 días.

    Se adjunta una copia en PDF de esta factura para sus registros.

    Si tiene alguna pregunta sobre esta factura, comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    ¡Gracias por participar en nuestro programa!
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number period_start_formatted period_end_formatted total_amount_formatted transactions_text_list support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_invoice_generated_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
