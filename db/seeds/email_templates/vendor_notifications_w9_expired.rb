# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_expired"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_expired.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_expired', format: :text, locale: 'en') do |template|
  template.subject = 'W9 Form Has Expired'
  template.description = 'Sent to a vendor when their W9 form on file has expired, requiring them to upload a new one to continue receiving payments.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    %<status_box_error_text>s
    %<status_box_warning_text>s

    Your W9 form expired on %<expiration_date_formatted>s.

    To resume payment processing for voucher transactions, please submit an updated W9 form as soon as possible.

    HOW TO SUBMIT YOUR UPDATED W9:
    1. Download the current W9 form from the IRS website: https://www.irs.gov/pub/irs-pdf/fw9.pdf
    2. Complete and sign the form
    3. Log in to your vendor portal at %<vendor_portal_url>s
    4. Navigate to "Profile" and upload your new W9 form

    %<status_box_info_text>s

    If you have already submitted an updated W9 form, please disregard this message.

    If you have any questions or need assistance, please contact our vendor support team immediately.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_error_text status_box_warning_text
                     expiration_date_formatted status_box_info_text vendor_portal_url footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_expired (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
