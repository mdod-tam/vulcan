# frozen_string_literal: true

# Seed File for "medical_provider_request_certification"
EmailTemplate.create_or_find_by!(name: 'medical_provider_request_certification', format: :text) do |template|
  template.subject = 'MEDICAL CERTIFICATION FORM REQUEST'
  template.description = 'Sent to a medical provider requesting they complete and submit a disability certification form for their patient.'
  template.body = <<~TEXT
    MEDICAL CERTIFICATION FORM REQUEST

    Dear Healthcare Provider,

    We are writing to request your completion of a disability certification form for your patient, %<constituent_full_name>s, who is applying for the Maryland Accessible Telecommunications Program to receive accessible telecommunications equipment to support independent telephone usage.

    %<request_count_message>s and was sent on %<timestamp_formatted>s.

    PATIENT INFORMATION:
    - Name: %<constituent_full_name>s
    - Date of Birth: %<constituent_dob_formatted>s
    - Address: %<constituent_address_formatted>s
    - Application ID: %<application_id>s

    To qualify for assistance through MAT, your patient requires documentation that they have a disability that makes it difficult for them to use a standard telephone. The certification form is essential for your patient to qualify for accessible telecommunications devices they need. To complete this form:

    1. Download the form at: %<download_form_url>s
    2. Complete all required fields
    3. Sign the form
    4. Return the completed form by email to medical-certification@maryland.gov or by fax to (410) 767-4276

    If you have questions or need assistance, please contact our medical certification team at more.info@maryland.gov or call (410) 767-6960.

    Thank you for your prompt attention to this important matter.

    Sincerely,
    Maryland Assistive Technology Program

    ---

    This email was sent regarding Application #%<application_id>s on behalf of %<constituent_full_name>s.
    CONFIDENTIALITY NOTICE: This email may contain confidential health information protected by state and federal privacy laws.
  TEXT
  template.version = 1
end
Rails.logger.debug 'Seeded medical_provider_request_certification (text)' if ENV['VERBOSE_TESTS'] || Rails.env.development?
