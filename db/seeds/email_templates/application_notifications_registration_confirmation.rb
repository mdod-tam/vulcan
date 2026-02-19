# frozen_string_literal: true

# Seed File for "application_notifications_registration_confirmation"
# --------------------------------------------------
EmailTemplate.create_or_find_by!(name: 'application_notifications_registration_confirmation', format: :text, locale: 'en') do |template|
  template.subject = 'Welcome to the Maryland Accessible Telecommunications Program'
  template.description = 'Sent to a user immediately after they register an account, outlining the program and next steps.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_full_name>s,

    Thank you for registering with the Maryland Accessible Telecommunications Program. We're here to help Maryland residents with hearing loss, vision loss, mobility impairments, speech impairments, and cognitive impairments access telecommunications devices that meet their needs.

    == PROGRAM OVERVIEW ==

    Our program provides vouchers to eligible Maryland residents to purchase accessible telecommunications products. You may be eligible if your household income is less than 400% of the federal poverty level for your family size.

    == NEXT STEPS ==

    To apply for assistance:

    1. Visit your dashboard to access your profile: %<dashboard_url>s
    2. Start a new application: %<new_application_url>s
    3. Complete all required information, including proofs of residency and income, and information for your medical provider
    4. Submit your application for review

    Once your application is approved, you'll receive a voucher that can be used to purchase eligible devices, along with information about available devices, vendors to purchase through, and resources for training.

    == AVAILABLE PRODUCTS ==

    We offer a variety of accessible telecommunications products for a range of disabilities, including:
    * Amplified phones for individuals with hearing loss
    * Specialized landline phones for individuals with vision loss or hearing loss
    * Smartphones (iPhone, iPad, Pixel) with accessibility features and applications to support multiple types of disabilities
    * Braille and speech devices for individuals wih speech differences
    * Communication aids for cognitive, memory or speech differences
    * Visual, audible, and tactile emergency alert systems

    == AUTHORIZED RETAILERS ==

    You can redeem your voucher at any of these authorized vendors:
    %<active_vendors_text_list>s

    Once your application is approved, you'll receive a voucher to purchase eligible devices through these vendors.

    If you have any questions about our program or need assistance with your application, please don't hesitate to contact us at more.info@maryland.gov or 410-697-9700.

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_full_name dashboard_url new_application_url active_vendors_text_list footer_text],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_registration_confirmation (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
