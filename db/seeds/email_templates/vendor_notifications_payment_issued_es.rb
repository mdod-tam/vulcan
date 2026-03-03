# frozen_string_literal: true

# Seed File for "vendor_notifications_payment_issued"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_payment_issued', format: :text, locale: 'es') do |template|
  template.subject = 'Pago Emitido'
  template.description = 'Enviado a un proveedor cuando el Departamento de Contabilidad General (GAD) ha emitido el pago de su factura.'
  template.body = <<~TEXT
    Pago Emitido

    Estimado/a %<vendor_business_name>s,

    Nos complace informarle que se ha emitido el pago de su factura.

    DETALLES DEL PAGO
    --------------
    Número de Factura: %<invoice_number>s
    Monto Total: %<total_amount_formatted>s
    Referencia GAD: %<gad_invoice_reference>s
    Número de Cheque: %<check_number>s

    INFORMACIÓN DE PAGO
    -----------------
    El pago ha sido emitido y debe recibirse de acuerdo con los términos de pago estándar.
    Por favor haga referencia al número de factura GAD en cualquier correspondencia futura sobre este pago.

    INFORMACIÓN DE CONTACTO
    -----------------
    Para preguntas sobre este pago:
    Departamento de Contabilidad General - tam.invoices@maryland.gov
    Referencia: número de factura GAD %<gad_invoice_reference>s

    Para todas las demás consultas:
    Equipo de Soporte - %<support_email>s

    ¡Gracias por su participación en nuestro programa!
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference support_email],
    'optional' => %w[check_number]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_payment_issued_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
