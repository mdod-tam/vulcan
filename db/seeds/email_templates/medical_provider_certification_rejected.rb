# frozen_string_literal: true

# Seed File for "medical_provider_certification_rejected"
template = EmailTemplate.find_or_initialize_by(name: 'medical_provider_certification_rejected', format: :text, locale: 'en')
template.subject = 'Disability Certification Rejected'
template.description = 'Sent to a medical provider when the submitted disability certification form is rejected.'
template.body = <<~TEXT
  MARYLAND ACCESSIBLE TELECOMMUNICATIONS

  DISABILITY CERTIFICATION FORM REJECTED

  Hello,

  We have received the disability certification form for the following individual:

  Name: %<constituent_full_name>s
  Application ID: %<application_id>s

  Unfortunately, the certification form has been rejected due to the following reason:

  %<rejection_reason>s

  NEXT STEPS

  Please submit a new disability certification form using one of the following methods:

  %<certification_resubmission_instructions>s

  Thank you for your assistance in helping the applicant access needed telecommunications services.

  Sincerely,
  Maryland Accessible Telecommunications Program

  ----------

  For questions, please contact us at mat.program1@maryland.gov or call 410-767-6960.
  Maryland Accessible Telecommunications (MAT) - Improving lives through accessible communication.
TEXT
template.variables = {
  'required' => %w[constituent_full_name application_id rejection_reason certification_resubmission_instructions],
  'optional' => []
}
template.version = 2
template.save! if template.new_record? || template.changed?
Rails.logger.debug 'Seeded medical_provider_certification_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
