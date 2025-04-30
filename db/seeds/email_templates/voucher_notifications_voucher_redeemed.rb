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
  template.version = 1
end
puts 'Seeded voucher_notifications_voucher_redeemed (text)'
