# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_assigned', format: :text, locale: 'en') do |template|
  template.subject = 'Your Voucher Has Been Assigned'
  template.description = 'Sent to the constituent when a voucher has been successfully generated and assigned to their approved application.'
  template.body = <<~TEXT
    Dear %<user_first_name>s,

    Congratulations! We are pleased to inform you that a voucher has been assigned to your application.

    Voucher Details:
    - Voucher Code: %<voucher_code>s
    - Value: %<initial_value_formatted>s
    - Expiration Date: %<expiration_date_formatted>s

    Important Information:
    * Your voucher is valid for %<validity_period_months>s months from today
    * The minimum redemption amount is %<minimum_redemption_amount_formatted>s
    * You can use this voucher at any of our approved vendors
    * Keep your voucher code secure and do not share it with others

    To use your voucher, simply present the code to any of our approved vendors. They will verify the code and process your purchase.

    If you have any questions about using your voucher, please don't hesitate to contact us.

    Thank you for participating in the Maryland Accessible Telecommunications Program.

    --
    Maryland Accessible Telecommunications Program
    Email: support@mdmat.org
    Website: https://mdmat.org

    This is an automated message. Please do not reply directly to this email.
  TEXT
  template.variables = {
    'required' => %w[user_first_name voucher_code initial_value_formatted expiration_date_formatted
                          validity_period_months minimum_redemption_amount_formatted],
    'optional' => []
  }                      
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
