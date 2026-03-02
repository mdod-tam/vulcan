# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_expired"
# EmailTemplate.find_by(name: 'voucher_notifications_voucher_expired').deliver(user: user, voucher: voucher)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expired', format: :text, locale: 'es') do |template|
  template.subject = 'Su Vale ha Expirado'
  template.description = 'Sent to the constituent when their assigned voucher has expired.'
  template.body = <<~TEXT
    %<header_text>s

    Estimado/a %<user_first_name>s,

    Lamentamos informarle que su vale ha expirado.

    Detalles del Vale Expirado:
    - Código de Vale: %<voucher_code>s
    - Valor Inicial: %<initial_value_formatted>s
    - Valor no Utilizado: %<unused_value_formatted>s
    - Fecha de Vencimiento: %<expiration_date_formatted>s

    %<transaction_history_text>s

    Qué Significa Esto:
    * El vale ya no se puede utilizar para compras
    * Cualquier saldo restante ha sido perdido
    * Puede ser elegible para un nuevo vale en el futuro

    Si cree que este vale expiró por error o tiene alguna pregunta, contáctenos de inmediato.

    Atentamente,
    El Equipo del Programa MAT

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name voucher_code initial_value_formatted unused_value_formatted
                     expiration_date_formatted footer_text],
    'optional' => %w[transaction_history_text]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expired_es (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
