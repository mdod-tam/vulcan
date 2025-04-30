# Seed File for "vendor_notifications_invoice_payment_issued"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_invoice_payment_issued.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_invoice_payment_issued', format: :text) do |template|
  template.subject = 'Payment Issued'
  template.description = 'Sent to a vendor when their invoice payment has been issued by the General Accounting Department (GAD).'
  template.body = <<~TEXT
    Payment Issued

    Dear %<vendor_business_name>s,

    We are pleased to inform you that your invoice payment has been issued by our General Accounting Department.

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
    Support Team - more.info@maryland.gov

    Thank you for your participation in our program!
  TEXT
  template.version = 1
end
puts 'Seeded vendor_notifications_invoice_payment_processed (text)'
