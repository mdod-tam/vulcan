# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_expiring_soon"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_expiring_soon.rb)
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'vendor_notifications_w9_expiring_soon', format: :text) do |template|
  template.subject = 'Action Required: Your W9 Form is Expiring Soon'
  template.description = 'Sent to a vendor as a warning that their W9 form on file is nearing its expiration date.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<vendor_business_name>s,

    %<status_box_warning_text>s

    Your W9 form will expire in %<days_until_expiry>s days on %<expiration_date_formatted>s.

    To ensure uninterrupted service and payment processing, please submit an updated W9 form before the expiration date.

    HOW TO SUBMIT YOUR UPDATED W9:
    1. Download the current W9 form from the IRS website: https://www.irs.gov/pub/irs-pdf/fw9.pdf
    2. Complete and sign the form
    3. Log in to your vendor portal at %<vendor_portal_url>s
    4. Navigate to "Profile" and upload your new W9 form

    If you have already submitted an updated W9 form, please disregard this message.

    %<status_box_info_text>s

    If you have any questions or need assistance, please contact our vendor support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text vendor_business_name status_box_warning_text days_until_expiry
                          expiration_date_formatted vendor_portal_url status_box_info_text footer_text],
    'optional' => []
  }                      
  template.version = 1
end
Rails.logger.debug 'Seeded vendor_notifications_w9_expiring_soon (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
