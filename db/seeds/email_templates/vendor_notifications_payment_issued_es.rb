# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'vendor_notifications_payment_issued', format: :text, locale: 'es') do |template|
  template.subject = 'Pago Emitido'
  template.description = 'Enviado a un proveedor cuando el Departamento de Contabilidad General (GAD) ha emitido el pago de su factura.'
  template.body = <<~TEXT
    Hola, %<vendor_business_name>s,

    Emitimos el pago de la factura %<invoice_number>s.

    Monto: %<total_amount_formatted>s
    Referencia de contabilidad: %<gad_invoice_reference>s
    %<check_number_line>s

    Para preguntas sobre el pago, escriba a tam.invoices@maryland.gov e incluya la referencia de contabilidad. Para otras consultas, escriba a %<support_email>s.
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference support_email],
    'optional' => %w[check_number_line]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_payment_issued_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
