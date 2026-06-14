# frozen_string_literal: true

# Seed File for "medical_provider_request_certification"
template = EmailTemplate.find_or_initialize_by(name: 'medical_provider_request_certification', format: :text, locale: 'en')
template.subject = 'DISABILITY CERTIFICATION FORM REQUEST'
template.description = 'Sent to a certifying professional requesting they complete and submit a disability certification form for an applicant.'
template.body = <<~TEXT
  DISABILITY CERTIFICATION FORM REQUEST

  Hello,

  %<constituent_full_name>s recently applied to the Maryland Accessible Telecommunications Program for equipment that supports independent telephone use. They listed you as a professional who can certify that they have a disability.

  %<request_count_message>s

   INFORMATION:
  - Name: %<constituent_full_name>s
  - Date of Birth: %<constituent_dob_formatted>s
  - Phone: %<constituent_phone_formatted>s
  - Email: %<constituent_email>s
  - Address: %<constituent_address_formatted>s
  - Application ID: %<application_id>s

  To qualify for assistance through MAT, this applicant requires documentation that they have a disability that makes it difficult for them to use a standard telephone. The certification form is essential for this applicant to qualify for accessible telecommunications devices they need. To complete this form:

  %<certification_submission_instructions>s

  If you have questions or need assistance, please contact our team at %<support_email>s or call (410) 767-6960.

  Thank you for your prompt attention to this important matter.

  Sincerely,
  Maryland Accessible Telecommunications Program

  ---

  This email was sent regarding Application #%<application_id>s on behalf of %<constituent_full_name>s.
  CONFIDENTIALITY NOTICE: This email may contain confidential health information protected by state and federal privacy laws.
TEXT
template.variables = {
  'required' => %w[constituent_full_name request_count_message constituent_dob_formatted constituent_phone_formatted constituent_email
                   constituent_address_formatted application_id certification_submission_instructions support_email],
  'optional' => []
}
template.version ||= 1
template.save!
Rails.logger.debug 'Seeded medical_provider_request_certification (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
