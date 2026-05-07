# frozen_string_literal: true

# Seed File for "vendor_notifications_w9_rejected"
# (Suggest saving as db/seeds/email_templates/vendor_notifications_w9_rejected.rb)
# --------------------------------------------------
template = EmailTemplate.find_or_initialize_by(name: 'vendor_notifications_w9_rejected', format: :text, locale: 'en')
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
  %<w9_resubmission_instructions>s

  Once you've submitted a corrected W9 form, our team will review it promptly.

  If you have any questions or need assistance, please don't hesitate to contact our team at %<support_email>s or call (410) 767-6960.

  Thank you for your cooperation.

  %<footer_text>s
TEXT
template.variables = {
  'required' => %w[header_text vendor_business_name status_box_text rejection_reason w9_resubmission_instructions footer_text support_email],
  'optional' => %w[secure_upload_url vendor_portal_url]
}
template.version = 2
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded vendor_notifications_w9_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
