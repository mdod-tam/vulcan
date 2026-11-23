# frozen_string_literal: true

EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_expiring_soon', format: :text, locale: 'en') do |template|
  template.subject = 'Important: Your Voucher Will Expire Soon'
  template.description = 'Sent to the constituent as a reminder that their voucher is nearing its expiration date.'
  template.body = <<~TEXT
    Dear %<vendor_business_name>s,

    Your voucher expires on %<expiration_date_formatted>s. You have %<remaining_value_formatted>s left. The minimum amount per purchase is %<minimum_redemption_amount_formatted>s.

    Voucher code: %<voucher_code>s

    For help, email %<support_email>s or call 410-767-6960.
  TEXT
  template.variables = {
    'required' => %w[vendor_business_name expiration_date_formatted remaining_value_formatted minimum_redemption_amount_formatted voucher_code support_email],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_expiring_soon (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
