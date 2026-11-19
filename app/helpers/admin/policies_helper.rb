# frozen_string_literal: true

module Admin
  module PoliciesHelper
    def mileage_rate_input_value(rate)
      value = rate.dollars_per_mile_before_type_cast
      value.is_a?(BigDecimal) ? value.to_s('F') : value
    end

    def mileage_rate_change_description(event)
      dates = event.field_change_pairs.fetch('effective_on', [event.metadata.fetch('effective_on')]).compact
      amounts = event.field_change_pairs.fetch('dollars_per_mile', [event.metadata.fetch('dollars_per_mile')]).compact
      date_labels = dates.map { |value| accessible_date_value(value) }
      amount_labels = amounts.map { |value| number_to_currency(value, precision: 3) }
      "Effective from #{date_labels.join(' → ')} · #{amount_labels.join(' → ')} per mile"
    end

    SYSTEM_POLICY_DETAILS = {
      'max_training_sessions' => {
        label: 'Training sessions per application', unit: 'sessions',
        description: 'Maximum sessions for one application, counting completed sessions and open training requests. ' \
                     'Applications eligible for iCanConnect have no session-count limit.'
      },
      'waiting_period_years' => {
        label: 'Application waiting and service period', unit: 'years',
        description: 'Sets the wait before reapplying and the evaluation/training service window. ' \
                     'Both are counted from the application date of an approved application.'
      },
      'sign_in_attempt_rate_limit_ip' => {
        label: 'Failed sign-ins per IP address', unit: 'failed attempts per time window',
        description: 'Limits wrong-password and unknown-account attempts from the same IP address. ' \
                     'Successful sign-ins do not count. Uses the failed sign-in time window.'
      },
      'sign_in_attempt_rate_period' => {
        label: 'Failed sign-in time window', unit: 'hours',
        description: 'Each IP address gets this many hours from its first failed sign-in before its count resets.'
      },
      'account_access_rate_limit_ip' => {
        label: 'Account access requests per IP address', unit: 'requests per time window',
        description: 'Limits requests for password-reset or account access instructions from the same IP address, ' \
                     'across all submitted emails and phones. Uses the account access time window.'
      },
      'account_access_rate_limit_contact_ip' => {
        label: 'Account access requests per email/phone and IP', unit: 'requests per time window',
        description: 'Limits requests for password-reset or account access instructions using the same submitted email or phone ' \
                     'from the same IP address. Uses the account access time window.'
      },
      'account_access_rate_limit_user_ip' => {
        label: 'Account access requests per account and IP', unit: 'requests per time window',
        description: 'Limits requests for password-reset or account access instructions for the same matched account ' \
                     'from the same IP address, even if different contacts are entered. Uses the account access time window.'
      },
      'account_access_rate_period' => {
        label: 'Account access time window', unit: 'hours',
        description: 'Time window for requests for password-reset or account access instructions. ' \
                     'Each request limit resets this many hours after its first counted request.'
      },
      'account_recovery_rate_limit_ip' => {
        label: 'Account recovery requests per IP address', unit: 'requests per time window',
        description: 'Limits requests for staff help recovering security-key access from the same IP address, ' \
                     'across all submitted emails and phones. Uses the account recovery time window.'
      },
      'account_recovery_rate_limit_contact_ip' => {
        label: 'Account recovery requests per email/phone and IP', unit: 'requests per time window',
        description: 'Limits requests for staff help recovering security-key access using the same submitted email or phone ' \
                     'from the same IP address. Uses the account recovery time window.'
      },
      'account_recovery_rate_limit_user_ip' => {
        label: 'Account recovery requests per account and IP', unit: 'requests per time window',
        description: 'Limits requests for staff help recovering security-key access for the same matched account ' \
                     'from the same IP address, even if different contacts are entered. Uses the account recovery time window.'
      },
      'account_recovery_rate_period' => {
        label: 'Account recovery time window', unit: 'hours',
        description: 'Time window for requests for staff help recovering security-key access. ' \
                     'Each request limit resets this many hours after its first counted request.'
      },
      'registration_rate_limit_ip' => {
        label: 'Sign-up verification requests per IP address', unit: 'requests per time window',
        description: 'Limits requests for sign-up verification emails from the same IP address, across all email addresses. ' \
                     'Uses the sign-up verification time window.'
      },
      'registration_rate_limit_contact' => {
        label: 'Sign-up verification requests per email address', unit: 'requests per time window',
        description: 'Limits requests for sign-up verification emails to the same email address, across all IP addresses. ' \
                     'Uses the sign-up verification time window.'
      },
      'registration_rate_period' => {
        label: 'Sign-up verification time window', unit: 'hours',
        description: 'Time window for sign-up verification email requests. ' \
                     'Each request limit resets this many hours after its first counted request.'
      },
      'contact_change_rate_limit_ip' => {
        label: 'Contact change requests per IP address', unit: 'requests per time window',
        description: 'Limits email/phone change requests and verification resends from the same IP address, across all accounts. ' \
                     'Uses the contact change time window.'
      },
      'contact_change_rate_limit_contact' => {
        label: 'Contact change requests per new email/phone', unit: 'requests per time window',
        description: 'Limits change requests and verification resends for the same proposed email or phone, across accounts and IP addresses. ' \
                     'Uses the contact change time window.'
      },
      'contact_change_rate_limit_user_ip' => {
        label: 'Contact change requests per account and IP', unit: 'requests per time window',
        description: 'Limits email/phone change requests and verification resends by the same signed-in account ' \
                     'from the same IP address. Uses the contact change time window.'
      },
      'contact_change_rate_period' => {
        label: 'Contact change time window', unit: 'hours',
        description: 'Time window for email/phone change requests and verification resends. ' \
                     'Each request limit resets this many hours after its first counted request.'
      },
      'sms_verification_rate_limit_contact' => {
        label: 'SMS verification sends per phone number', unit: 'send attempts per time window',
        description: 'Limits attempts to send verification codes to the same phone number, across accounts, IP addresses and verification purposes. ' \
                     'Does not count code-entry attempts. Uses the SMS verification time window.'
      },
      'sms_verification_rate_period' => {
        label: 'SMS verification time window', unit: 'hours',
        description: 'Each phone number gets this many hours from its first counted verification-code send attempt before its count resets.'
      },
      'secure_form_link_expiration_hours' => {
        label: 'Secure request link lifetime', unit: 'hours',
        description: 'How long a newly issued proof, provider-information, disability-certification or vendor W-9 upload link remains valid.'
      },
      'secure_form_resend_cooldown_hours' => {
        label: 'Wait before replacing a secure request link', unit: 'hours',
        description: 'Minimum wait after sending an open secure request before sending its replacement. ' \
                     'Applies to proof, provider-information, disability-certification and vendor W-9 requests.'
      },
      'max_proof_rejections' => {
        label: 'Saved proof rejection limit (unused)', unit: 'rejections (not used)',
        description: 'This saved value does not affect proof reviews. The app uses its fixed rejection limit instead.'
      },
      'organization_name' => {
        label: 'Organization name (not a numeric setting)', unit: 'text cannot be entered here',
        description: 'Some message footers read this key, but this editor stores whole numbers and cannot save an organization name.'
      },
      'minimum_voucher_redemption_amount' => {
        label: 'Voucher message minimum', unit: 'dollars shown in messages',
        description: 'Amount shown as the minimum in voucher messages. Actual redemption uses the separate minimum under Voucher Policies.'
      }
    }.freeze

    def format_policy_value(key, value)
      case key
      when /^fpl_\d+_person$/, 'fpl_additional_person'
        number_to_currency(value)
      when 'fpl_modifier_percentage'
        "#{value}%"
      else
        value.to_s
      end
    end

    def system_policy_details(key)
      SYSTEM_POLICY_DETAILS.fetch(key) do
        { label: key.humanize, unit: 'unit not documented',
          description: 'The purpose and units of this saved setting are not documented. Confirm its use before changing it.' }
      end
    end
  end
end
