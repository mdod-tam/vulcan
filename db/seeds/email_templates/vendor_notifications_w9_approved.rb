# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_approved"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_approved.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_approved', format: :text, locale: 'en') do |template|
  template.subject = 'W9 Form Approved'
  template.description = 'Sent to a vendor when their submitted W9 form has been reviewed and approved, activating their account.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    We are pleased to inform you that your W9 form has been reviewed and approved.

    %<status_box_text>s

    Your vendor account is now fully activated, and you can begin processing vouchers through our system.

    If you have any questions or need assistance, please don't hesitate to contact our support team at %<support_email>s or call (410) 767-6960.

    Thank you for your partnership.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_text footer_text support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_approved (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
