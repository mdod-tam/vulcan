# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_expiring_soon"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expiring_soon', format: :text, locale: 'en') do |template|
  template.subject = 'Important: Your Voucher Will Expire Soon'
  template.description = 'Sent to the vendor as a reminder that their voucher is nearing its expiration date.'
  template.body = <<~TEXT
    Important: Your Voucher Will Expire Soon

    Dear %<vendor_business_name>s,

    This is a reminder that your voucher will expire in %<days_until_expiry>s days on %<expiration_date_formatted>s.

    %<status_box_warning_text>s
    %<status_box_info_text>s

    Voucher Details:
    - Voucher Code: %<voucher_code>s
    - Remaining Value: %<remaining_value_formatted>s
    - Expiration Date: %<expiration_date_formatted>s

    Important Reminders:
    * Any unused value will be forfeited after the expiration date
    * The minimum redemption amount is %<minimum_redemption_amount_formatted>s
    * Contact us immediately if you have any issues using your voucher

    To ensure you don't lose your voucher value, please make arrangements to use it before the expiration date.

    If you need assistance or have any questions, please don't hesitate to contact us.

    Best regards,
    The MAT Program Team
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name days_until_expiry expiration_date_formatted status_box_warning_text
                     status_box_info_text voucher_code remaining_value_formatted minimum_redemption_amount_formatted],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expiring_soon (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
