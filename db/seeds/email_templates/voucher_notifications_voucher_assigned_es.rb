# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_assigned', format: :text, locale: 'es') do |template|
  template.subject = 'Su Vale Ha Sido Asignado'
  template.description = 'Sent to the constituent when a voucher has been generated and assigned to their approved application.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    ¡Excelentes noticias! Su vale de Telecomunicaciones Accesibles de Maryland está listo para usar.

    DETALLES DE SU VALE:
    Código de Vale: %<voucher_code>s
    Valor: %<initial_value_formatted>s
    Fecha de Vencimiento: %<expiration_date_formatted>s

    REGLAS IMPORTANTES:
    * Su vale es válido por %<validity_period_months>s meses a partir de hoy.
    * El monto mínimo de compra es %<minimum_redemption_amount_formatted>s.
    * Por favor, guarde su código de vale en un lugar seguro y no lo comparta.

    ¿QUÉ PUEDO COMPRAR?
    Puede usar su vale para comprar equipos de telecomunicaciones accesibles, incluyendo:
    * Teléfonos inteligentes (como iPhone, iPad o Pixel) con funciones de accesibilidad
    * Teléfonos amplificados para pérdida de audición
    * Teléfonos fijos especializados para pérdida de visión o audición
    * Productos de braille y habla
    * Ayudas de comunicación para diferencias cognitivas, de memoria o de habla
    * Sistemas de alerta visual, audible y táctil

    CÓMO USAR SU VALE:
    Puede usar su vale en cualquiera de nuestros proveedores autorizados. Simplemente proporcione su código de vale y se le pedirá que verifique su fecha de nacimiento para procesar la compra.

    Si tiene alguna pregunta, responda a este correo electrónico o comuníquese con nuestro equipo al %<support_email>s o llame al (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name voucher_code initial_value_formatted expiration_date_formatted validity_period_months
                     minimum_redemption_amount_formatted footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_assigned_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
