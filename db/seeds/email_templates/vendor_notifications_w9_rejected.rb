# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_rejected"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_rejected.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_rejected', format: :text) do |template|
  template.subject = 'W9 Form Requires Correction'
  template.description = 'Sent to a vendor when their submitted W9 form has been rejected and requires corrections.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    We have reviewed your submitted W9 form and found that it requires some corrections before we can proceed.

    %<status_box_text>s

    Reason for Rejection:
    %<rejection_reason>s

    Next Steps:
    1. Please log in to your vendor account: %<vendor_portal_url>s
    2. Navigate to your profile settings
    3. Upload a corrected W9 form

    Once you've submitted a corrected W9 form, our team will review it promptly.

    If you have any questions or need assistance, please don't hesitate to contact our support team.

    Thank you for your cooperation.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_text rejection_reason vendor_portal_url
                          footer_text],
    'optional' => []
  }                      
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
