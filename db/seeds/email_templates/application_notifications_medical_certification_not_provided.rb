# frozen_string_literal: true

# Seed File for "application_notifications_medical_certification_not_provided"
EmailTemplate.create_or_find_by!(name: 'application_notifications_medical_certification_not_provided', format: :text) do |template|
  template.subject = 'Disability Certification Required for Your Application'
  template.description = 'Sent to a constituent when they submit an application without providing disability certification or provider contact information, or when a submitted certification has been rejected.'
  template.body = <<~TEXT
    %<header_text>s

    Dear %<user_first_name>s,

    Thank you for submitting your application to the Maryland Accessible Telecommunications Program. We have received your submission and are beginning our review process.

    However, we noticed that your application is missing disability certification information. To complete your application, we need documentation from a qualified professional confirming your disability.

    NEXT STEPS:

    1. Email our team at mat.program1@maryland.gov.
    2. Provide either:
       - A qualifying provider contact information (name, email, phone, fax), OR
       - Upload a completed disability certification form

    3. Our team will then contact your medical provider to request the necessary certification.

    WHAT IS NEEDED:

    We require a disability certification form completed by a qualified professional (physician, psychiatrist, psychologist, social worker, or other qualified provider) who can confirm that you have a disability that makes it difficult for you to use a standard telephone.

    %<rejection_reason_message>s

    If you have questions about what documentation is needed or need assistance, please contact our support team.

    Application ID: %<application_id>s

    %<footer_text>s
  TEXT
  template.variables = {
    'required' => %w[header_text user_first_name application_id footer_text],
    'optional' => %w[rejection_reason_message]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded application_notifications_medical_certification_not_provided (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
