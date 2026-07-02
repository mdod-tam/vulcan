# PII Encryption

MAT Vulcan uses Rails Active Record Encryption for sensitive user and credential data. This guide explains what is encrypted, how lookups should work, and what not to break.

---

## 1. Current Encryption Model

Rails stores encrypted values in the normal logical columns. There are no separate `_encrypted` columns for the current user-profile fields.

Encryption is configured in `config/initializers/active_record_encryption.rb`:

- keys are read from `Rails.application.credentials.active_record_encryption`
- `extend_queries` is disabled
- `support_unencrypted_data` is enabled for transition compatibility
- fixtures are encrypted
- key references are stored
- encrypted attributes are added to parameter filtering

The initializer falls back to temporary keys when credentials are missing. That is useful for development/test, but persistent environments need stable credentials or encrypted data will not survive key changes.

---

## 2. User Fields

User-profile encryption is declared in `UserProfile`.

| Field | Mode | Why |
| --- | --- | --- |
| `email` | deterministic | Login and uniqueness lookup. |
| `phone` | deterministic | Contact lookup and uniqueness validation. |
| `dependent_email` | deterministic | Dependent contact lookup. |
| `dependent_phone` | deterministic | Dependent contact lookup. |
| `ssn_last4` | deterministic | Stored sensitive identifier fragment. |
| `date_of_birth` | deterministic | DOB checks and voucher verification. |
| `password_digest` | non-deterministic | Password hash is already one-way, but still stored encrypted. |
| `physical_address_1` | non-deterministic | Sensitive address data; not used for equality lookup. |
| `physical_address_2` | non-deterministic | Sensitive address data; not used for equality lookup. |
| `city` | non-deterministic | Address data. |
| `state` | non-deterministic | Address data. |
| `zip_code` | non-deterministic | Address data. |

Deterministic encryption means the same plaintext produces the same ciphertext. That makes equality queries and unique indexes possible, but it leaks equality. Use it only where the application needs lookup or uniqueness behavior.

---

## 3. Credential And Secure Request Fields

Other encrypted fields include:

| Model | Field | Mode |
| --- | --- | --- |
| `TotpCredential` | `secret` | non-deterministic |
| `WebauthnCredential` | `public_key` | non-deterministic |
| `SecureRequestForm` | `recipient_email`, `recipient_phone` | deterministic |
| `MedicalProviderSecureRequestForm` | `provider_email` | deterministic |
| `VendorSecureRequestForm` | `recipient_email` | deterministic |
| `Application` | `document_signing_audit_url`, `document_signing_document_url` | non-deterministic |

The WebAuthn public key is not secret in the cryptographic sense, but the model encrypts it at rest. The parameter filter intentionally omits `public_key` while still filtering credential secrets such as TOTP secrets.

---

## 4. Query Rules

Use the helper methods on `User` for contact lookup:

- `User.find_by_email(value)`
- `User.find_by_phone(value)`
- `User.find_by_login_identifier(value)` — public sign-in, account recovery, and other login-identity lookups; email-backed portal accounts only for phone-shaped input (`real_email?` and `real_phone?` required on the matched user); treats any `@` input as email-shaped, rejects malformed email strings without falling back to phone, and blocks synthetic dependent contacts
- `User.exists_with_email?(value, excluding_id: nil)`
- `User.exists_with_phone?(value, excluding_id: nil)`

These helpers normalize email and phone values before querying and rescue lookup failures with a warning.

Current adoption by path:

- `User.find_by_login_identifier` — public sign-in and account recovery (email-backed portal accounts only; phone lookup requires `real_email?` and `real_phone?` on the matched user)
- `User.find_by_email` / `User.find_by_phone` — registration duplicate checks, paper intake, and other existing lookup paths
- `User.find_for_account_access` — account-access identity lookup plus separate delivery selection in `PasswordsController#create`

Direct Rails equality queries on deterministic encrypted fields can work, but new code should use the helpers where contact lookup or uniqueness is the point. That keeps normalization and failure behavior consistent.

Do not use fuzzy SQL matching, lower/LIKE queries, or partial matching against encrypted fields. Those patterns do not work reliably against encrypted values.

---

## 5. Validation And Uniqueness

`UserProfile` validates email and phone uniqueness through the helper methods.

Important behavior:

- email is normalized to lowercase before validation
- phone is normalized to `XXX-XXX-XXXX` when it has a valid 10-digit US shape
- email is required unless paper context allows a no-email paper flow, the user is a persisted phone-only record (`email_optional?` — NULL email with `real_phone?`, not an email-backed portal account), or the user is a persisted address-only constituent (`real_email?` and `real_phone?` both false with letter delivery)
- phone and dependent phone must be valid 10-digit US numbers when present
- dependent email/phone are encrypted too

The users table also has unique indexes for email and phone, so validation is not the only protection against duplicate contacts.

---

## 6. Logging And Filtering

Sensitive request parameters are filtered in `config/initializers/filter_parameter_logging.rb`.

Currently filtered categories include:

- password fields
- user contact and address fields, including unified auth `contact`
- date of birth and SSN fields
- SMS phone number params
- medical provider contact fields
- encrypted-column suffixes
- TOTP secrets and broad token/key/certificate patterns

Do not add new PII fields without updating both encryption declarations and parameter filtering.

Reset URLs, verification URLs, and secure upload URLs are bearer delivery artifacts, not durable record truth. Mailer and SMS failure logs must pass exception messages and backtraces through `SecureErrorSanitizer`; SMS paths carrying those links must also use `sensitive: true` so message bodies and full phone numbers are not written to logs.

---

## 7. Testing

Main coverage lives in `test/models/user_encrypted_validation_test.rb`.

The tests check:

- encrypted attributes are declared
- encrypted values remain readable through Rails models
- raw database values differ from plaintext for encrypted user contact fields
- email and phone uniqueness work
- helper methods work with encrypted contact fields
- encryption config has `extend_queries: false` and `support_unencrypted_data: true`

When adding a new encrypted field, add coverage for:

- model declaration
- normal read/write behavior
- query helper behavior if the field is deterministic
- parameter filtering if the field can arrive in request params

---

## 8. Operational Notes

Keep these constraints in mind:

- Production credentials must be stable. Temporary fallback keys are not safe for persistent encrypted data.
- Database backups require the matching encryption keys to restore useful data.
- Deterministic fields are queryable but reveal equality patterns.
- Encrypted data takes more space than plaintext; column lengths were widened where needed.
- `support_unencrypted_data` is still enabled, so transition-era plaintext rows may still be readable.
- `extend_queries` is disabled, so avoid relying on Rails to search multiple encrypted/plain forms of a value.

Key rotation is not automated in this doc. If rotation is needed, plan it as an operational task: configure previous keys, verify decryptability, re-save affected records, and remove old keys only after validation.

---

## 9. Change Rules

When changing PII storage:

- Add encryption in the owning model or concern.
- Use deterministic encryption only when equality lookup or uniqueness is required.
- Add or update helper methods for normalized lookup fields.
- Update parameter filtering for fields that can appear in request params.
- Keep tests close to the model behavior.
- Avoid raw SQL against encrypted values except for narrow verification or data repair.
- Do not log plaintext values while debugging encryption issues.

Primary code paths:

- `app/models/concerns/user_profile.rb`
- `app/models/user.rb`
- `app/models/totp_credential.rb`
- `app/models/webauthn_credential.rb`
- `app/models/secure_request_form.rb`
- `app/models/medical_provider_secure_request_form.rb`
- `app/models/vendor_secure_request_form.rb`
- `app/models/application.rb`
- `config/initializers/active_record_encryption.rb`
- `config/initializers/filter_parameter_logging.rb`
- `test/models/user_encrypted_validation_test.rb`
