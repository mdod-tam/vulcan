# frozen_string_literal: true

# Seed File for "medical_provider_certification_rejected"
EmailTemplate.create_or_find_by!(name: 'medical_provider_certification_rejected', format: :text) do |template|
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

    1. Email: Reply to this email with the updated certification form attached
    2. Fax: Send the updated form to 410-767-4276

    Note: The application has %<remaining_attempts>s remaining submission attempts before they must reapply.

    Thank you for your assistance in helping this applicant access needed telecommunications services.

    Sincerely,
    Maryland Accessible Telecommunications Program

    ----------

    For questions, please contact us at medical-cert@mdmat.org or call 410-767-6960.
    Maryland Accessible Telecommunications (MAT) - Improving lives through accessible communication.
  TEXT
  template.variables = {
    'required' => %w[constituent_full_name application_id rejection_reason remaining_attempts],
    'optional' => []
  }
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_certification_rejected (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
