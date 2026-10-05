# frozen_string_literal: true

require_relative '../../lib/webhooks/email_events_parameter_filter'

# After you modify this file, restart the server.

# Parameter filters limit sensitive data in logs. String and symbol filters match partial parameter names.
# See ActiveSupport::ParameterFilter for supported notations and behavior.
Rails.application.config.filter_parameters += [
  # Password-related fields
  :password, :password_confirmation, :current_password, :password_digest,

  # Contact, identity, and address data
  :email, :phone, :contact, :details, :email_hint, :ssn_last4, :date_of_birth,
  :physical_address_1, :physical_address_2, :city, :state, :zip_code,

  # Identity review and paper intake submit names with birth dates and addresses.
  :first_name, :middle_initial, :last_name,

  # The paper identity receipt binds a creation decision to reviewed facts. Keep it and the rationale out of logs.
  # Legacy token filters do not match these parameter names.
  :identity_decision, :identity_review_receipt, :identity_rationale, /_signed_id\z/,

  # Autosave wraps income, disability, and provider details in a generic value parameter.
  :autosave_context, :field_value,

  # SMS contact
  :phone_number,

  # Medical provider PII fields
  :medical_provider_name, :medical_provider_phone, :medical_provider_email, :medical_provider_fax,

  # Encrypted columns and IVs (regex patterns)
  /_encrypted\z/, /_encrypted_iv\z/,

  # Authentication credential secrets
  :secret, /\A(?:HTTP_)?Authorization\z/i,
  # The legacy /_key\z/ filter also matches public_key.

  # Legacy filters also match names outside the explicit lists.
  /passw/, /\btoken\z/, /_key\z/, /crypt/, /salt/, /certificate/, /\botp\z/, /\bssn\z/, /cvv/, /cvc/
]

# Redact Postmark parameters before request logging, including rejected callbacks.
Rails.application.config.middleware.insert_before Rails::Rack::Logger, Webhooks::EmailEventsParameterFilter
