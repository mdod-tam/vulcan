# PII Encryption

Rails encrypts selected attributes before storing them and decrypts them when models read them.

Values stay in their normal columns; there are no separate `_encrypted` columns for current user-profile fields.

Encryption covers the declarations below, not every piece of personal information in the database.

## What is encrypted?

| Owner | Deterministic fields | Other encrypted fields |
| --- | --- | --- |
| [UserProfile](../../app/models/concerns/user_profile.rb) | `email`, `phone`, `dependent_email`, `dependent_phone`, `ssn_last4`, `date_of_birth` | `password_digest`, `physical_address_1`, `physical_address_2`, `city`, `state`, `zip_code` |
| [TotpCredential](../../app/models/totp_credential.rb) | — | `secret` |
| [WebauthnCredential](../../app/models/webauthn_credential.rb) | — | `public_key` |
| [SecureRequestForm](../../app/models/secure_request_form.rb) | `recipient_email`, `recipient_phone` | — |
| [MedicalProviderSecureRequestForm](../../app/models/medical_provider_secure_request_form.rb) | `provider_email` | — |
| [VendorSecureRequestForm](../../app/models/vendor_secure_request_form.rb) | `recipient_email` | — |
| [Application](../../app/models/application.rb) | — | `document_signing_audit_url`, `document_signing_document_url` |

Deterministic encryption produces matching ciphertext for matching values under the same encryption configuration. This supports equality queries and unique indexes, but reveals equality patterns. Use it only when lookup or uniqueness requires it.

The password digest is a BCrypt hash that is also encrypted at rest. A WebAuthn public key is not a cryptographic secret, though this application encrypts its stored value.

## Looking up encrypted contacts

`User.find_by_email`, `find_by_phone`, `exists_with_email?`, and `exists_with_phone?` are the contact lookup and uniqueness path. They share one normalization — lowercased email, and `XXX-XXX-XXXX` formatting for valid US numbers — which is what makes a deterministic match possible at all, since the ciphertext of an unnormalized value differs. Database unique indexes back the same two columns.

Public sign-in and recovery use `find_by_login_identifier`; account-access requests use `find_for_account_access`. These enforce eligibility beyond a matching contact value. A phone-only paper record must not become a public login account through a generic contact lookup. See [authentication](authentication_system.md) and [user management](../development/user_management_features.md).

SQL `LOWER`, `LIKE`, and substring matching operate on ciphertext and silently return nothing useful. Admin email search works around that with the separate HMAC search tokens in [UserEmailSearch](../../app/models/concerns/user_email_search.rb).

## Keys and existing data

[The initializer](../../config/initializers/active_record_encryption.rb) reads `primary_key`, `deterministic_key`, and `key_derivation_salt` from `Rails.application.credentials.active_record_encryption`.

**Persistent environments need stable keys.** Missing credentials trigger temporary random keys; the fallback is not restricted to development. Losing the matching keys makes encrypted records unreadable, including restored backups.

Two settings matter during migrations:

- `support_unencrypted_data: true` allows existing plaintext values to be read.
- `extend_queries: false` means equality searches do not automatically cover both plaintext and encrypted representations.

Fixtures are encrypted and key references are stored. These settings do not establish automated key rotation. Plan rotation with previous-key support, deterministic lookup and uniqueness checks, data migration, and a tested restore before retiring old keys.

## Keep personal data out of logs

[Parameter filtering](../../config/initializers/filter_parameter_logging.rb) covers contact details, names, addresses, DOB, password fields, provider contacts, and tokens. Paper identity receipts, rationales, and upload `*_signed_id` parameters are filtered, as is the legacy `identity_decision` parameter from older forms. Encrypted attributes are also added to filtering. Review storage and filtering together when adding a sensitive field.

SQL binds need names for filtering to work. A hash condition carries its column name; a positional value in `where('LOWER(first_name) = ?', value)` does not. [Constituent duplicate matching](../../app/models/users/constituent.rb) uses named query attributes for this reason.

Reset, verification, and secure-upload links are bearer credentials: anything holding one durably — notification metadata, an unsanitized delivery error — is a second copy of the credential. [SecureErrorSanitizer](../../app/services/concerns/secure_error_sanitizer.rb) strips them from mailer and SMS failures, and SMS carrying one is sent with `sensitive: true`.

## What breaks when a field changes

An encrypted field has four surfaces that fail independently: the model's own reads and writes, the raw stored value, the normalized lookup and uniqueness path where one applies, and request and query-log filtering. A field can round-trip correctly through the model while its plaintext still reaches the logs, and a deterministic field can encrypt correctly while its uniqueness check quietly stops matching.

[Encrypted validation tests](../../test/models/user_encrypted_validation_test.rb) and [parameter filtering tests](../../test/config/filter_parameter_logging_test.rb) cover the first and last of those. Operational requirements are in the [security baseline](baseline_policy.md).
