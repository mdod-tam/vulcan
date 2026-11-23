# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'vendor_notifications_payment_issued', format: :text, locale: 'en') do |template|
  template.subject = 'Payment Issued'
  template.description = 'Sent to a vendor when their invoice payment has been issued by the General Accounting Department (GAD).'
  template.body = <<~TEXT
    Dear %<vendor_business_name>s,

    We issued payment for invoice %<invoice_number>s.

    Amount: %<total_amount_formatted>s
    Accounting reference: %<gad_invoice_reference>s
    %<check_number_line>s

    For payment questions, email tam.invoices@maryland.gov and include the accounting reference. For other questions, email %<support_email>s.
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference support_email],
    'optional' => %w[check_number_line]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_payment_issued (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
