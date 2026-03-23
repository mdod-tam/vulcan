# frozen_string_literal: true

# Seed File for "vendor_notifications_payment_issued"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_payment_issued', format: :text, locale: 'en') do |template|
  template.subject = 'Payment Issued'
  template.description = 'Sent to a vendor when their invoice payment has been issued by the General Accounting Department (GAD).'
  template.body = <<~TEXT
    Payment Issued

    Dear %<vendor_business_name>s,

    We are pleased to inform you that your invoice payment has been issued.

    PAYMENT DETAILS
    --------------
    Invoice Number: %<invoice_number>s
    Total Amount: %<total_amount_formatted>s
    GAD Reference: %<gad_invoice_reference>s
    Check Number: %<check_number>s

    PAYMENT INFORMATION
    -----------------
    The payment has been issued and should be received according to standard payment terms.
    Please reference the GAD invoice number in any future correspondence about this payment.

    CONTACT INFORMATION
    -----------------
    For questions about this payment:
    General Accounting Department - tam.invoices@maryland.gov
    Reference: GAD invoice number %<gad_invoice_reference>s

    For all other inquiries:
    Support Team - %<support_email>s

    Thank you for your participation in our program!
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name invoice_number total_amount_formatted gad_invoice_reference support_email],
    'optional' => %w[check_number]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_payment_issued (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
