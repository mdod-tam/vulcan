# PII Encryption

Rails encrypts selected fields before storing them and decrypts them when the application reads them. In Rails terms these are model attributes, each backed by a database column.

Values stay in their normal columns. There are no separate `_encrypted` columns for current user-profile fields.

Encryption covers the declarations below, not every piece of personal information in the database.

## What is encrypted?

| Owner | Deterministic fields | Other encrypted fields |
| --- | --- | --- |
| [UserProfile](../../app/models/concerns/user_profile.rb) | `email`, `phone`, `dependent_email`, `dependent_phone`, `ssn_last4`, `date_of_birth` | `password_digest`, `physical_address_1`, `physical_address_2`, `city`, `state`, `zip_code`, `business_tax_id` |
| [TotpCredential](../../app/models/totp_credential.rb) | — | `secret` |
| [WebauthnCredential](../../app/models/webauthn_credential.rb) | — | `public_key` |
| [SecureRequestForm](../../app/models/secure_request_form.rb) | `recipient_email`, `recipient_phone` (a certification link's `recipient_email` is the provider's) | — |
| [VendorSecureRequestForm](../../app/models/vendor_secure_request_form.rb) | `recipient_email` | — |
| [Application](../../app/models/application.rb) | — | `document_signing_audit_url`, `document_signing_document_url` |
| [EmailDeliveryAttempt](../../app/models/email_delivery_attempt.rb) | — | `destination` |
| [EquipmentItem](../../app/models/equipment_item.rb) | `normalized_imei`, `normalized_serial_number` | `imei`, `serial_number`, `tracking_number` |
| [Event](../../app/models/event.rb) | — | `change_values` (see [audit events](#audit-events)) |

Deterministic encryption produces matching ciphertext for matching values under the same encryption configuration. Ciphertext is the encrypted form of a value. This supports equality searches and unique indexes, but it reveals which values match. Use it only when lookup or uniqueness requires it.

Equipment identifiers use normalized encrypted equality for duplicate checks. Normalized means reformatted to one standard form before comparing. Partial database indexes enforce one active IMEI — a device identifier for mobile equipment — and one active serial within the recorded normalized manufacturer/model identity, including duplicate catalog entries. Shipped and detached devices retain those assignments. Withdrawn historical devices release them. Device identifier corrections use the encrypted audit values described below, and identifiers are excluded from bid exports.

### Audit events

[`AuditEventService.log`](../../app/services/audit_event_service.rb) applies one [audit privacy policy](../../app/services/audit_metadata_privacy.rb) before logging or storing metadata. Personal changes keep their existing old/new, from/to, or array shape. Emails retain the first character of the local part and domain plus the final domain suffix; phone and tax IDs retain their last four digits; names retain initials. Birth dates, street addresses, cities, ZIP codes, notes, identity rationale, and free-text rejection/decline reasons are withheld. Passwords, digests, tokens, and bearer links retain no fragments. Boolean presence flags, record IDs, reason codes, sources, actors, and event times remain usable. Workflow records retain their own authorized detail views.

The same classifications apply inside nested hashes and record collections. An enclosing secret or withheld field also protects its nested values. Staff name snapshots, including assignment and completion names, are masked. The actor's exact `Event#user_id`, its account association, and any role metadata remain intact; authorized views can resolve that account's current identity. Masked name snapshots do not replace accountable actor IDs or their access-controlled account records.

Encrypted model declarations supplement the explicit personal-field classifications. Masked personal changes are stored directly in `Event#metadata`, with no copy in `Event#change_values` and no masking step in the history reader. Device serial, IMEI, tracking, and duplicate-identity acknowledgment history keeps its encrypted storage and authorized operational readers. `Event#field_changes` combines metadata changes with these encrypted device values; `field_change_pairs` supports the live old/new, from/to, and array callers. This pre-release change adds no conversion or compatibility path for historical personal-value audit storage.

The password digest is a BCrypt hash that is also encrypted at rest. A WebAuthn public key is not a cryptographic secret, though this application encrypts its stored value.

## Training content and public product guidance

Training report `internal_notes`, `constituent_summary`, and private cancellation and no-show reasons are not encrypted attributes. Their audience is controlled by application and session authorization. Current staff and trainer views can resolve preparation and private notes. Former trainers retain only their own completed-report access.

The applicant or current managing guardian receives the deliberately authored shared summary. Shared text is not inferred from private notes. Completion notifications link to the authenticated report instead of copying private report content into delivery metadata. Adding note encryption would require a separate design for both training and evaluation content.

Product resources have a different audience: they are public program guidance with an explicit language and exact catalog-product target. Resource PDFs use signed Active Storage proxy links without a resource-specific login guard. Editors must not include personal, application, or session information in a resource URL or file. Device associations and shared training history remain authorized even though their linked guidance is public. A demo model's guidance can appear on its authorized training summary without adding that model to Devices.

## Looking up encrypted contacts

`User.find_by_email`, `find_by_phone`, `exists_with_email?`, and `exists_with_phone?` are the contact lookup and uniqueness path. They share one normalization: lowercased email, and `XXX-XXX-XXXX` formatting for valid US numbers. That is what makes a deterministic match possible at all, because the ciphertext of an unnormalized value differs. Database unique indexes back the same two columns.

Public sign-in and recovery use `find_by_login_identifier`. Account-access requests use `find_for_account_access`. These enforce eligibility beyond a matching contact value. A phone-only paper record must not become a public login account through a generic contact lookup. See [authentication](authentication_system.md) and [user management](../development/user_management_features.md).

Database search functions such as SQL `LOWER`, `LIKE`, and substring matching operate on ciphertext and silently return nothing useful. Admin email search works around that with separate HMAC search tokens in [UserEmailSearch](../../app/models/concerns/user_email_search.rb). An HMAC token is a keyed fingerprint that can match a value without revealing it.

## Keys and encrypted storage

[The initializer](../../config/initializers/active_record_encryption.rb) reads `primary_key`, `deterministic_key`, and `key_derivation_salt` from `Rails.application.credentials.active_record_encryption`.

**Configure stable keys before saving records.** Normal non-test startup, including development, refuses missing, incomplete, or blank encryption credentials before serving requests, starting jobs, or running database tasks. The error names the missing entries and the credentials-edit command for the environment. Temporary random keys are limited to disposable test runs. Complete configured keys are reused in tests too.

The secretless build exception applies only when `assets:precompile` is the sole requested Rake task, a command-line job the framework runs. Missing encryption keys stay unset in that process; encrypted data operations still require their configured keys. `SECRET_KEY_BASE_DUMMY` alone does not bypass runtime validation, and combining precompilation with a database task is rejected. The Docker build removes Rails' temporary signing-secret file before copying the application into the final image.

Run `bin/rails db:encryption:init` to generate keys for initial setup. Save all three entries in the matching credentials file before saving records, and reuse them across application instances and restarts. Losing the matching keys makes encrypted records unreadable.

`RAILS_MASTER_KEY` decrypts the credentials file, not database columns. A replacement instance can use a different master key only with credentials re-encrypted under it that preserve the original Active Record keys and salt. Preserve the effective `secret_key_base` too. Besides signed cookies and links, it supplies the HMAC key for the persisted email-search index. Changing it requires rebuilding those tokens.

Use the [backup checklist and settings comparison](../infrastructure/backup_and_recovery.md) for recovery.

Encrypted storage has one representation:

- `support_unencrypted_data: false` rejects plaintext stored values for encrypted attributes, including deterministic contact fields.
- `extend_queries: false` keeps equality searches on their encrypted representation.

Rails encrypts fixture values before storage through `encrypt_fixtures: true`; plaintext fixture source files do not require plaintext database reads. Key references are stored with ciphertext. This pre-release application has no plaintext conversion task or mixed-storage compatibility mode.

## Keep personal data out of logs

Diagnostic logs and error reports use the exception class and limited context such as record IDs. Exception messages, backtraces, validation text, and rejected metadata can contain personal data or credentials. Keep them out of diagnostics, including messages passed through shared logging helpers. Expected validation feedback can still explain a rejected form to the person submitting it. Unexpected application-creation failures show a generic message in the user's language.

[Parameter filtering](../../config/initializers/filter_parameter_logging.rb) covers contact details, names, addresses, DOB (date of birth), password fields, provider contacts, and tokens. Paper identity receipts, rationales, and upload `*_signed_id` parameters are filtered. The filter also covers `identity_decision` as defense in depth. Autosave filters `field_value`, which can contain personal data, and its `autosave_context` page identifier. Encrypted attributes are also added to filtering. Review storage and filtering together when adding a sensitive field.

Training request filters cover exact `internal_notes`, `constituent_summary`, cancellation and no-show reason keys, and reschedule reasons. Audit and notification metadata contains structural training facts instead of those text bodies. [Product resource filtering](../../config/initializers/product_resource_parameter_filter.rb) hides uploaded document parameters, signed upload references, resource URLs, and manufacturer-documentation URLs. Model filtering also hides resource and manufacturer URLs from SQL and inspection output, because an external URL can carry query credentials even when its guidance is public.

Equipment request filtering covers serial, IMEI, tracking, correction reasons, and the signed `impact_token` confirmation payload. That signature binds the reviewed values. It does not encrypt the payload, so it needs explicit log filtering even when the individual identifier fields are filtered. The staff access dialog posts its signed impact token as `confirmation`, which is filtered under that exact name so unrelated fields that mention confirmation stay visible.

SQL binds need names for filtering to work. A bind is a query value sent separately from the SQL text. A hash condition carries its column name. A positional value in `where('LOWER(first_name) = ?', value)` does not. [Constituent duplicate matching](../../app/models/users/constituent.rb) uses named query attributes for this reason.

Reset, verification, and secure-upload links are bearer credentials: anyone holding the link can use it, like a password in the URL. Anything that durably holds one — notification metadata, an unsanitized delivery error — is a second copy of the credential. [`SecureErrorSanitizer`](../../app/services/concerns/secure_error_sanitizer.rb) strips them from mailer and SMS failures. An SMS carrying one is sent with `sensitive: true`.

## What breaks when a field changes

An encrypted field has four surfaces that fail independently: the model's own reads and writes, the raw stored value, the normalized lookup and uniqueness path where one applies, and request and query-log filtering. A field can round-trip correctly through the model while its plaintext still reaches the logs. A deterministic field can encrypt correctly while its uniqueness check quietly stops matching.

[Encrypted validation tests](../../test/models/user_encrypted_validation_test.rb) and [parameter filtering tests](../../test/config/filter_parameter_logging_test.rb) cover the first and last of those. Operational requirements are in the [security baseline](baseline_policy.md).
