# PII Encryption

Rails encrypts selected attributes before storing them and decrypts them when models read them.

Values stay in their normal columns; there are no separate `_encrypted` columns for current user-profile fields.

Encryption covers the declarations below, not every piece of personal information in the database.

## What is encrypted?

| Owner | Deterministic fields | Other encrypted fields |
| --- | --- | --- |
| [UserProfile](../../app/models/concerns/user_profile.rb) | `email`, `phone`, `dependent_email`, `dependent_phone`, `ssn_last4`, `date_of_birth` | `password_digest`, `physical_address_1`, `physical_address_2`, `city`, `state`, `zip_code`, `business_tax_id` |
| [TotpCredential](../../app/models/totp_credential.rb) | — | `secret` |
| [WebauthnCredential](../../app/models/webauthn_credential.rb) | — | `public_key` |
| [SecureRequestForm](../../app/models/secure_request_form.rb) | `recipient_email`, `recipient_phone` | — |
| [MedicalProviderSecureRequestForm](../../app/models/medical_provider_secure_request_form.rb) | `provider_email` | — |
| [VendorSecureRequestForm](../../app/models/vendor_secure_request_form.rb) | `recipient_email` | — |
| [Application](../../app/models/application.rb) | — | `document_signing_audit_url`, `document_signing_document_url` |
| [EmailDeliveryAttempt](../../app/models/email_delivery_attempt.rb) | — | `destination` |
| [EquipmentItem](../../app/models/equipment_item.rb) | `normalized_imei`, `normalized_serial_number` | `imei`, `serial_number`, `tracking_number` |
| [Event](../../app/models/event.rb) | — | `change_values` (see [audit events](#audit-events)) |

Deterministic encryption produces matching ciphertext for matching values under the same encryption configuration. This supports equality queries and unique indexes, but reveals equality patterns. Use it only when lookup or uniqueness requires it.

Equipment identifiers use normalized encrypted equality for duplicate checks. Partial database indexes enforce one active IMEI and one active serial within the recorded normalized manufacturer/model identity, including duplicate catalog entries. Shipped and detached devices retain those assignments; withdrawn historical devices release them. Device identifier corrections use the encrypted audit values described below, and identifiers are excluded from bid exports.

### Audit events

`Event#metadata` is plain JSON, so it must not hold values whose columns are encrypted. When `metadata[:changes]` names an encrypted record field or an explicitly sensitive audit field, [`AuditEventService.log`](../../app/services/audit_event_service.rb) keeps the field name in metadata, with an empty placeholder, and moves its old and new values to the encrypted `Event#change_values`. The sensitive-field list includes `serial_duplicate_reason`: an equipment acknowledgment may contain a device identifier even though it is not a stored EquipmentItem attribute. Read recorded changes with `Event#field_changes`, which restores those values; reading `metadata['changes']` directly shows only the names. Other change fields are stored as given.

The password digest is a BCrypt hash that is also encrypted at rest. A WebAuthn public key is not a cryptographic secret, though this application encrypts its stored value.

## Looking up encrypted contacts

`User.find_by_email`, `find_by_phone`, `exists_with_email?`, and `exists_with_phone?` are the contact lookup and uniqueness path. They share one normalization — lowercased email, and `XXX-XXX-XXXX` formatting for valid US numbers — which is what makes a deterministic match possible at all, since the ciphertext of an unnormalized value differs. Database unique indexes back the same two columns.

Public sign-in and recovery use `find_by_login_identifier`; account-access requests use `find_for_account_access`. These enforce eligibility beyond a matching contact value. A phone-only paper record must not become a public login account through a generic contact lookup. See [authentication](authentication_system.md) and [user management](../development/user_management_features.md).

SQL `LOWER`, `LIKE`, and substring matching operate on ciphertext and silently return nothing useful. Admin email search works around that with the separate HMAC search tokens in [UserEmailSearch](../../app/models/concerns/user_email_search.rb).

## Keys and existing data

[The initializer](../../config/initializers/active_record_encryption.rb) reads `primary_key`, `deterministic_key`, and `key_derivation_salt` from `Rails.application.credentials.active_record_encryption`.

**Retained data needs stable keys.** Normal non-test startup, including development, refuses missing, incomplete or blank encryption credentials. The error names the missing entries and the credentials-edit command for the environment. Temporary random keys are limited to disposable test runs and asset builds with `SECRET_KEY_BASE_DUMMY=1` and `assets:precompile` as the sole requested Rake task. Complete configured keys are reused in those paths too.

When initializing fresh data, use `bin/rails db:encryption:init` to generate keys, then save all three entries in the matching credentials file before saving records. Preserve the original encryption keys and salt for any data you retain; temporary keys cannot reliably read records after a restart, and losing the matching keys makes encrypted records unreadable, including restored backups.

`RAILS_MASTER_KEY` decrypts the credentials file, not database columns. A replacement instance can use a different master key only with credentials re-encrypted under it that preserve the original Active Record keys and salt. Preserve the effective `secret_key_base` too: besides signed cookies/links, it supplies the HMAC key for the persisted email-search index. Changing it requires rebuilding those tokens.

Use the [backup checklist and settings comparison](../infrastructure/backup_and_recovery.md) for recovery. See the [vendor tax-record cutover](../infrastructure/vendor_tax_records_cutover.md) for the stable-key check, resumable TIN/audit conversion, W9 storage-key rotation, and cache invalidation order.

Two settings matter during migrations:

- `support_unencrypted_data: true` allows existing plaintext values to be read.
- `extend_queries: false` means equality searches do not automatically cover both plaintext and encrypted representations.

Fixtures are encrypted and key references are stored. These settings do not establish automated key rotation. Plan rotation with previous-key support, deterministic lookup and uniqueness checks, data migration, and a tested restore before retiring old keys.

## Keep personal data out of logs

[Parameter filtering](../../config/initializers/filter_parameter_logging.rb) covers contact details, names, addresses, DOB, password fields, provider contacts, and tokens. Paper identity receipts, rationales, and upload `*_signed_id` parameters are filtered. The filter also covers `identity_decision` as defense in depth. Autosave filters `field_value`, which can contain personal data, and its `autosave_context` page identifier. Encrypted attributes are also added to filtering. Review storage and filtering together when adding a sensitive field.

Equipment request filtering covers serial, IMEI, tracking, correction reasons, and the signed `impact_token` confirmation payload. That signature binds reviewed values; it does not encrypt the payload, so it needs explicit log filtering even when the individual identifier fields are filtered.

SQL binds need names for filtering to work. A hash condition carries its column name; a positional value in `where('LOWER(first_name) = ?', value)` does not. [Constituent duplicate matching](../../app/models/users/constituent.rb) uses named query attributes for this reason.

Reset, verification, and secure-upload links are bearer credentials: anything holding one durably — notification metadata, an unsanitized delivery error — is a second copy of the credential. [SecureErrorSanitizer](../../app/services/concerns/secure_error_sanitizer.rb) strips them from mailer and SMS failures, and SMS carrying one is sent with `sensitive: true`.

## What breaks when a field changes

An encrypted field has four surfaces that fail independently: the model's own reads and writes, the raw stored value, the normalized lookup and uniqueness path where one applies, and request and query-log filtering. A field can round-trip correctly through the model while its plaintext still reaches the logs, and a deterministic field can encrypt correctly while its uniqueness check quietly stops matching.

[Encrypted validation tests](../../test/models/user_encrypted_validation_test.rb) and [parameter filtering tests](../../test/config/filter_parameter_logging_test.rb) cover the first and last of those. Operational requirements are in the [security baseline](baseline_policy.md).
