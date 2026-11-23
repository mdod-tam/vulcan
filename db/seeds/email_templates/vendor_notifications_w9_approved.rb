# frozen_string_literal: true

EmailTemplate.find_or_create_by!(name: 'vendor_notifications_w9_approved', format: :text, locale: 'en') do |template|
  template.subject = 'W9 Form Approved'
  template.description = 'Sent to a vendor when their submitted W9 form has been reviewed and approved. Program authorization is a separate step.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    We approved your W9. Check your vendor dashboard for any remaining steps to redeem vouchers.

    For help, email %<support_email>s or call 410-767-6960.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name support_email footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_approved (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
