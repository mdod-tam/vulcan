# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_redeemed"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_redeemed', format: :text) do |template|
  template.subject = 'Voucher Successfully Redeemed at Your Business'
  template.description = 'Sent to the vendor when a constituent redeems a voucher at their business.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    We are confirming that a voucher has been successfully redeemed at your business by %<user_first_name>s.

    Transaction Details:
    - Voucher Code: %<voucher_code>s
    - Transaction Date: %<transaction_date_formatted>s
    - Transaction Amount: %<transaction_amount_formatted>s
    - Transaction Reference: %<transaction_reference_number>s
    - Expiration Date: %<expiration_date_formatted>s

    Voucher Status:
    - Value Redeemed: %<redeemed_value_formatted>s
    - Remaining Balance: %<remaining_balance_formatted>s
    %<remaining_value_message_text>s
    %<fully_redeemed_message_text>s

    Payment for this transaction will be processed according to your vendor agreement. You can view all your transaction history in your vendor portal.

    If you have any questions about this transaction, please contact our vendor support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name user_first_name voucher_code transaction_date_formatted
                          transaction_amount_formatted transaction_reference_number expiration_date_formatted
                          redeemed_value_formatted remaining_balance_formatted remaining_value_message_text
                          fully_redeemed_message_text footer_text],
    'optional' => []
  }                      
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_redeemed (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
