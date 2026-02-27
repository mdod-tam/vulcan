# frozen_string_literal: true

# Seed File for "voucher_notifications_voucher_assigned"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'voucher_notifications_voucher_assigned', format: :text, locale: 'en') do |template|
  template.subject = 'Your Voucher Has Been Assigned'
  template.description = 'Sent to the constituent when a voucher has been generated and assigned to their approved application.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Great news! Your Maryland Accessible Telecommunications voucher is ready to use.

    YOUR VOUCHER DETAILS:
    Voucher Code: %<voucher_code>s
    Value: %<initial_value_formatted>s
    Expiration Date: %<expiration_date_formatted>s

    IMPORTANT RULES:
    * Your voucher is valid for %<validity_period_months>s months from today.
    * The minimum purchase amount is %<minimum_redemption_amount_formatted>s.
    * Please keep your voucher code safe and do not share it.

    WHAT CAN I BUY?
    You can use your voucher to purchase accessible telecommunications equipment, including:
    * Smartphones (like iPhone, iPad, or Pixel) with accessibility features
    * Amplified phones for hearing loss
    * Specialized landline phones for vision or hearing loss
    * Braille and speech products
    * Communication aids for cognitive, memory, or speech differences
    * Visual, audible, and tactile alerting systems

    HOW TO USE YOUR VOUCHER:
    You can use your voucher at any of our authorized vendors. Simply give them your voucher code and they will ask to verify your date of birth to process the purchase.

    If you have any questions, please reply to this email or contact our support team.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name voucher_code initial_value_formatted expiration_date_formatted
                     validity_period_months minimum_redemption_amount_formatted footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded voucher_notifications_voucher_assigned (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
