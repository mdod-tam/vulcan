# frozen_string_literal: true

# Seeds EN rejection reason records from the authoritative strings in
# app/views/admin/applications/_modals.html.erb.
#
# address_mismatch body uses a %{address} placeholder so it can be
# interpolated with the applicant's actual address at send time.
# All other bodies are static.
def seed_rejection_reasons
  reasons = [
    # ── Income ────────────────────────────────────────────────────────────
    {
      code: 'address_mismatch',
      proof_type: 'income',
      body: 'The address provided on your income documentation does not match ' \
            'the application address. Please submit documentation that contains ' \
            'the address exactly matching the one shared in your application: %{address}'
    },
    {
      code: 'expired',
      proof_type: 'income',
      body: 'The income documentation you provided is more than 1 year old or is ' \
            'expired. Please submit documentation that is less than 1 year old and ' \
            'which is not expired.'
    },
    {
      code: 'missing_name',
      proof_type: 'income',
      body: 'The income documentation you provided does not show your name. Please ' \
            'submit documentation that clearly displays your full name as it appears ' \
            'on your application.'
    },
    {
      code: 'wrong_document',
      proof_type: 'income',
      body: 'The document you submitted is not an acceptable type of income proof. ' \
            'Please submit one of the following: recent pay stubs, tax returns, ' \
            'Social Security benefit statements, or other official documentation ' \
            'that verifies your income.'
    },
    {
      code: 'missing_amount',
      proof_type: 'income',
      body: 'The income documentation you provided does not clearly show your income ' \
            'amount. Please submit documentation that clearly displays your income ' \
            'figures, such as pay stubs with earnings clearly visible or benefit ' \
            'statements showing payment amounts.'
    },
    {
      code: 'exceeds_threshold',
      proof_type: 'income',
      body: 'Based on the income documentation you provided, your household income ' \
            'exceeds the maximum threshold to qualify for the MAT program. The program ' \
            'is designed to assist those with financial need, and unfortunately, your ' \
            'income level is above our current eligibility limits.'
    },
    {
      code: 'outdated_ss_award',
      proof_type: 'income',
      body: 'Your Social Security benefit award letter is out-of-date. Please submit ' \
            'your most recent award letter, which should be dated within the last 12 ' \
            'months. You can obtain a new benefit verification letter by visiting the ' \
            'Social Security Administration website or contacting your local SSA office.'
    },

    # ── Residency ──────────────────────────────────────────────────────────
    {
      code: 'address_mismatch',
      proof_type: 'residency',
      body: 'The address provided on your residency documentation does not match ' \
            'the application address. Please submit documentation that contains ' \
            'the address exactly matching the one shared in your application: %{address}'
    },
    {
      code: 'expired',
      proof_type: 'residency',
      body: 'The residency documentation you provided is more than 1 year old or is ' \
            'expired. Please submit documentation that is less than 1 year old and ' \
            'which is not expired.'
    },
    {
      code: 'missing_name',
      proof_type: 'residency',
      body: 'The residency documentation you provided does not show your name. Please ' \
            'submit documentation that clearly displays your full name as it appears ' \
            'on your application.'
    },
    {
      code: 'wrong_document',
      proof_type: 'residency',
      body: 'The document you submitted is not an acceptable type of residency proof. ' \
            'Please submit one of the following: utility bill, lease agreement, mortgage ' \
            'statement, or other official documentation that verifies your Maryland residence.'
    },

    # ── Medical Certification ──────────────────────────────────────────────
    {
      code: 'missing_provider_credentials',
      proof_type: 'medical_certification',
      body: "The disability certification is missing required provider credentials or " \
            "license number. Please ensure the resubmitted form includes the certifying " \
            "professional's full credentials and license information."
    },
    {
      code: 'incomplete_disability_documentation',
      proof_type: 'medical_certification',
      body: 'The documentation of the disability is incomplete. The certification must ' \
            'include a complete description of the disability and how it affects major ' \
            'life activities.'
    },
    {
      code: 'outdated_certification',
      proof_type: 'medical_certification',
      body: 'The disability certification is outdated. Please provide a certification ' \
            'that has been completed within the last 12 months.'
    },
    {
      code: 'missing_signature',
      proof_type: 'medical_certification',
      body: 'The disability certification is missing the required signature from the ' \
            'certifying professional. Please ensure the resubmitted form is properly ' \
            'signed and dated.'
    },
    {
      code: 'missing_functional_limitations',
      proof_type: 'medical_certification',
      body: 'The disability certification lacks sufficient detail about functional ' \
            'limitations. Please ensure the resubmitted form includes specific ' \
            'information about how the disability affects daily activities.'
    },
    {
      code: 'incorrect_form_used',
      proof_type: 'medical_certification',
      body: 'The wrong certification form was used. Please ensure the certifying ' \
            'professional completes the official Disability Certification Form for ' \
            'MAT program eligibility.'
    }
  ]

  reasons.each do |attrs|
    RejectionReason.find_or_create_by!(
      code: attrs[:code],
      proof_type: attrs[:proof_type],
      locale: 'en'
    ) do |r|
      r.body = attrs[:body]
    end
  end

  seed_puts "Seeded #{RejectionReason.count} rejection reason(s)."
end
