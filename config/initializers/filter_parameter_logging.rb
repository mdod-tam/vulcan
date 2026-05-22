# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  # Password-related fields
  :password, :password_confirmation, :current_password, :password_digest,

  # PII fields (plaintext) - User model
  :email, :phone, :ssn_last4, :date_of_birth,
  :physical_address_1, :physical_address_2, :city, :state, :zip_code,

  # SMS credential specific field
  :phone_number,

  # Medical provider PII fields
  :medical_provider_name, :medical_provider_phone, :medical_provider_email, :medical_provider_fax,

  # Encrypted columns and IVs (regex patterns)
  /_encrypted\z/, /_encrypted_iv\z/,

  # Authentication credential secrets
  :secret,
  # NOTE: public_key omitted as it's not secret data in cryptographic terms

  # Legacy broad filters (be careful with these)
  /passw/, /\btoken\z/, /_key\z/, /crypt/, /salt/, /certificate/, /\botp\z/, /\bssn\z/, /cvv/, /cvc/
]
