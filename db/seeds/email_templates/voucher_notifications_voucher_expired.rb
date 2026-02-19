# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_expired"
# EmailTemplate.find_by(name: 'voucher_notifications_voucher_expired').deliver(user: user, voucher: voucher)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expired', format: :text, locale: 'en') do |template|
  template.subject = 'Your Voucher Has Expired'
  template.description = 'Sent to the constituent when their assigned voucher has expired.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    We regret to inform you that your voucher has expired.

    Expired Voucher Details:
    - Voucher Code: %<voucher_code>s
    - Initial Value: %<initial_value_formatted>s
    - Unused Value: %<unused_value_formatted>s
    - Expiration Date: %<expiration_date_formatted>s

    %<transaction_history_text>s

    What This Means:
    * The voucher can no longer be used for purchases
    * Any remaining balance has been forfeited
    * You may be eligible for a new voucher in the future

    If you believe this voucher expired in error or have any questions, please contact us immediately.

    Best regards,
    The MAT Program Team

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name voucher_code initial_value_formatted unused_value_formatted
                          expiration_date_formatted footer_text],
    'optional' => %w[transaction_history_text]  
  }                    
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expired (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
