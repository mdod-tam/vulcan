# frozen_string_literal: true

# Seed File for "vendor_notifications_invoice_generated"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_invoice_generated.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_invoice_generated', format: :text, locale: 'en') do |template|
  template.subject = 'New Invoice Generated'
  template.description = 'Sent to a vendor when a new invoice has been generated based on their recent voucher transactions.'
  template.body = <<~TEXT
    New Invoice Generated

    Dear %<vendor_business_name>s,

    A new invoice has been generated for your recent voucher transactions.

    INVOICE DETAILS
    --------------
    Invoice Number: %<invoice_number>s
    Period: %<period_start_formatted>s - %<period_end_formatted>s
    Total Amount: %<total_amount_formatted>s

    TRANSACTION SUMMARY
    -----------------
    %<transactions_text_list>s

    NEXT STEPS
    ---------
    Our accounting team will review this invoice and process payment within 30 days.

    A PDF copy of this invoice is attached for your records.

    If you have any questions about this invoice, please contact our support team at more.info@maryland.gov.

    Thank you for participating in our program!
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number period_start_formatted period_end_formatted
                     total_amount_formatted transactions_text_list],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_invoice_generated (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
