# frozen_string_literal: true

# Seed File for "medical_provider_certification_approved"
EmailTemplate.create_or_find_by!(name: 'medical_provider_certification_approved', format: :text, locale: 'en') do |template|
  template.subject = 'Signed Disability Certification Received and Approved'
  template.description = 'Sent to the signer when their signed disability certification copy is received and approved.'
  template.body = <<~TEXT
    MARYLAND ACCESSIBLE TELECOMMUNICATIONS

    SIGNED DISABILITY CERTIFICATION RECEIVED

    Hello,

    This is to confirm that your signed disability certification copy has been received and approved.

    Name: %<constituent_full_name>s
    Application ID: %<application_id>s

    No further action is needed at this time.

    Thank you for taking the time to complete and submit the signed certification.

    Sincerely,
    Maryland Accessible Telecommunications Program

    ----------

    For questions, please contact us at mat.program1@maryland.gov or call 410-767-6960.
  TEXT
  template.variables = {
    'required' => %w[constituent_full_name application_id],
    'optional' => %w[support_email]
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_certification_approved (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
