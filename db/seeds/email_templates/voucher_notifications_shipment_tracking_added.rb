# frozen_string_literal: true

# Seed File for "voucher_notifications_shipment_tracking_added"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_shipment_tracking_added', format: :text, locale: 'en') do |template|
  template.subject = 'A package from %<vendor_business_name>s is on its way'
  template.description = 'Sent to the applicant, or the guardian managing the application, when a vendor records tracking for a package.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    %<vendor_business_name>s has sent a package from your voucher purchase on %<transaction_date_formatted>s.

    Tracking number: %<tracking_number>s

    Your order may arrive in more than one package. Every package recorded for this purchase is listed in your account.

    Orders and shipping page:
    %<orders_url>s

    If you have questions about your order, contact %<vendor_business_name>s or our team at %<support_email>s or (410) 767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name vendor_business_name transaction_date_formatted tracking_number orders_url support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_shipment_tracking_added (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
