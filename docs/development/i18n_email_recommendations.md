# i18n, Rejection Reasons & Mailer Simplification Recommendations

## Proposed Architecture

All user-facing email content lives in the database — already true for email templates. The strategy is to extend that pattern consistently:

- **Email templates** (`EmailTemplate`) — `locale` column added; each template gets one row per locale. At send time, look up by `(name, format, locale)` and fall back to `'en'`.
- **Rejection reasons** — new `RejectionReason` model with the same shape as `EmailTemplate`: `code`, `proof_type`, `locale`, `body`, versioned, admin-editable.
- **`proof_reviews`** — add a `rejection_reason_code` string column (the stable key linking a review to a reason record).
- **`User.locale`** — already exists as a string column on the `users` table; determines which locale variant is fetched at send time.

No yml files for any user-facing content. Everything admin-controlled, versioned, and translatable without a code deploy.

---

## Current State

### EmailTemplate (as of Feb 2026)

- DB-stored, admin-editable via `Admin::EmailTemplatesController`.
- Unique index on `(name, format, locale)` — both `html` and `text` variants exist for each template name.
- `ApplicationNotificationsMailer#find_email_template` looks up by `(name, format, locale)` with English fallback.
- `%{variable}` / `%<variable>s` interpolation in `body` and `subject`.
- `version` integer increments on each `subject` or `body` change; `previous_subject`/`previous_body` store one level of undo.
- `locale` column exists (string, not null, default `'en'`). EN templates explicitly set `locale: 'en'` in seeds, and ES variants are seeded as EN copies when missing.
- `needs_sync` boolean flag (default `false`): set on locale variants when a counterpart's body/subject changes; cleared automatically when that variant is saved with new content.

### Rejection Reasons (what currently exists and what's wrong)

`proof_reviews.rejection_reason` stores the **full English sentence** typed by the admin. No stable code is saved. This locks every downstream use — email bodies, letters, audit logs — into English forever.

The predefined reason strings live in two places today:

1. **`app/views/admin/applications/_modals.html.erb`** — Ruby locals built with `h("...")` and passed as controller-level Stimulus `data-rejection-form-*-value` attributes. The strings only live here; `rejection_form_controller.js` reads them via the Stimulus values API (no hardcoding in JS).
2. **`app/javascript/controllers/users/document_proof_handler_controller.js`** — hardcoded reason/instruction maps were removed. UI now reads reason text from server-provided `data-reason-text` attributes.

`ProofReview.proof_type` is an enum with `income: 0`, `residency: 1`, and `medical_certification: 2` (prefixed). Medical certification rejections are stored on `proof_reviews` (proof_type: medical_certification), with backward-compatible read delegators on `Application` via `CertificationManagement`.

The full set of predefined codes (source: `_modals.html.erb` and `rejection_form_controller.js`):

| Code | Proof types |
|---|---|
| `address_mismatch` | income, residency |
| `expired` | income, residency |
| `missing_name` | income, residency |
| `wrong_document` | income, residency |
| `missing_amount` | income only |
| `exceeds_threshold` | income only |
| `outdated_ss_award` | income only |
| `missing_signature` | income, residency, medical cert |
| `illegible` | income, residency, medical cert |
| `incomplete_documentation` | income, residency |
| `missing_provider_credentials` | medical cert |
| `incomplete_disability_documentation` | medical cert |
| `outdated_certification` | medical cert |
| `missing_functional_limitations` | medical cert |
| `incorrect_form_used` | medical cert |

### Known gaps to fix before i18n work is meaningful

**Constituents do not receive email when a medical cert is rejected — this is intentional.** The certification is submitted by a healthcare provider (the signer), not the constituent. Rejection is the signer's problem to fix. The constituent tracks status via their dashboard and application show page.

`'medical_certification_rejected'` is correctly absent from `NotificationService::MAILER_MAP`. The in-app `Notification` record (associated with the constituent) is sufficient for their visibility.

**The provider email path — works correctly.** The full delivery chain when a cert is rejected:

```
MedicalCertificationAttachmentService.send_rejection_notification
  → NotificationService.create_and_deliver!(
      type: 'medical_certification_rejected',
      recipient: application.user,          # constituent — notification record only
      metadata: { 'reason' => ..., ... })
  → resolve_mailer: MAILER_MAP['medical_certification_rejected']
      → [MedicalProviderMailer, :rejected]
  → send_notification_email (else branch):
      MedicalProviderMailer.public_send(:rejected, notifiable, notification).deliver_later
  → MedicalProviderMailer#rejected (proxy):
      self.class.with(application:,
        rejection_reason: notification.metadata['reason'],
        ...).certification_rejected
  → certification_rejected: sends to application.medical_provider_email ✓
```

**Remaining gap: `MedicalProviderNotifier` implementation complete** ✅ — The fax/email-to-provider notification path is now fully wired and functional. See `docs/development/medical_provider_notification_implementation.md` for implementation details. This work was completed as part of Track C.

---

## Part 1: Add Locale to EmailTemplate ✅ Done

### Schema change ✅

Migration `20260217000001_add_locale_to_email_templates` added:

```ruby
add_column :email_templates, :locale, :string, null: false, default: 'en'
add_column :email_templates, :needs_sync, :boolean, null: false, default: false
remove_index :email_templates, name: 'index_email_templates_on_name'
add_index :email_templates, [:name, :format, :locale], unique: true,
                            name: 'index_email_templates_on_name_format_locale'
```

Existing records default to `'en'`. ES variants are seeded (or created via the admin UI) with `locale: 'es'`.

### Mailer lookup ✅

`ApplicationNotificationsMailer#find_email_template` now accepts a locale and falls back to English:

```ruby
def find_email_template(template_name, locale: 'en')
  EmailTemplate.find_by!(name: template_name, format: :text, locale: locale)
rescue ActiveRecord::RecordNotFound => e
  raise if locale == 'en'

  Rails.logger.debug { "No #{locale} template for #{template_name}, falling back to English" }
  find_email_template(template_name, locale: 'en')
end
```

Each public mailer method derives the locale from the recipient:

```ruby
def proof_rejected(application, proof_review)
  locale = application.user.locale.presence || 'en'
  text_template = find_email_template(template_name, locale: locale)
  # ...
end
```

Admin-only emails (e.g. `proof_needs_review_reminder`) always use `'en'`. `income_threshold_exceeded` passes the constituent through `ParameterNormalizationService`, which now extracts `locale` alongside the other constituent fields, so it also respects the user's locale.

### Sync enforcement ✅

`EmailTemplate` enforces that locale variants don't silently drift apart:

```ruby
# Flags other locales when this template's content changes.
# Guard: skipped when needs_sync is already true (that save is fixing the sync).
after_update :flag_counterpart_locales_for_sync,
             if: -> { (saved_change_to_body? || saved_change_to_subject?) && !needs_sync? }

# Clears our own flag after a content update that resolved the out-of-sync state.
after_update :clear_sync_flag,
             if: -> { (saved_change_to_body? || saved_change_to_subject?) && needs_sync? }

# Blocks saves that don't actually change content while out-of-sync.
# Saving with new body/subject is always allowed — that's how you fix the sync.
validate :counterpart_locales_are_synced, on: :update
```

### Admin UI ✅

- **Index** — Locale column shows locale badge (`EN`/`ES`). Status column shows amber "Needs Sync" badge when `needs_sync: true`.
- **Show** — Locale appears in the template details grid. Amber warning banner appears when `needs_sync: true`, with a "Mark Synced" button to dismiss.
- **Edit/Form** — Amber warning at the top when `needs_sync: true`, explaining the situation and offering a "Mark Synced" escape hatch.
- **`mark_synced` action** — `PATCH /admin/email_templates/:id/mark_synced` clears `needs_sync` without requiring content changes (for when the existing translation is still correct).

### Remaining for Part 1

- ✅ **Seeds** — EN template seeds now explicitly set `locale: 'en'`.
- ✅ **ES baseline variants** — seed pass now creates missing ES variants as EN copies (without overwriting existing ES content).
- ✅ **Side-by-side dual edit UI** — edit page shows EN and ES panels together, each editable at the same time with independent `Save EN` / `Save ES` actions.
- ✅ **Missing counterpart creation in-place** — when one locale is missing, the edit page shows explicit `Create EN from ES` / `Create ES from EN` actions.
- ✅ **Clear locale metadata + sync cues** — each panel shows locale-specific "Last updated (EN/ES)" text and a `Needs sync` / `In sync` badge.

---

## Part 2: RejectionReason Model

### Schema

```ruby
# migration
create_table :rejection_reasons do |t|
  t.string  :code,         null: false   # e.g. "address_mismatch"
  t.string  :proof_type,   null: false   # "income", "residency", or "medical_certification"
  t.string  :locale,       null: false, default: 'en'
  t.text    :body,         null: false
  t.integer :version,      null: false, default: 1
  t.text    :previous_body
  t.bigint  :updated_by_id
  t.timestamps
  t.index [:code, :proof_type, :locale], unique: true
end
```

Note: `proof_type` here is a plain string (not a foreign key to `ProofReview`'s integer enum). Use `"income"`, `"residency"`, and `"medical_certification"` as values so the medical cert track can share the same model.

### Model

```ruby
class RejectionReason < ApplicationRecord
  belongs_to :updated_by, class_name: 'User', optional: true

  before_update :store_previous_body
  before_update :increment_version
  after_update  :flag_counterpart_locales_for_sync, if: :saved_change_to_body?

  validate :counterpart_locales_are_synced, on: :update

  def self.resolve(code:, proof_type:, locale: 'en')
    find_by(code: code, proof_type: proof_type, locale: locale) ||
      find_by(code: code, proof_type: proof_type, locale: 'en')
  end

  private

  def store_previous_body
    self.previous_body = body_was if body_changed?
  end

  def increment_version
    self.version += 1 if body_changed?
  end

  def flag_counterpart_locales_for_sync
    RejectionReason.where(code: code, proof_type: proof_type).where.not(locale: locale)
                   .update_all(needs_sync: true)
  end

  def counterpart_locales_are_synced
    return unless needs_sync?
    errors.add(:base, 'All locale variants must be updated together.')
  end
end
```

Seed the initial records from the strings already in `_modals.html.erb` (the authoritative source today).

### proof_reviews change

```ruby
# migration
add_column :proof_reviews, :rejection_reason_code, :string
```

When an admin submits a rejection, save the code alongside the existing free text:

```ruby
# in the proof review form / controller
proof_review.update!(
  rejection_reason: reason_text,      # keep for legacy / "Other" fallback display
  rejection_reason_code: reason_code  # new — nil for "Other"/custom reasons
)
```

### Mailer lookup at send time

```ruby
def build_proof_rejected_variables(application, proof_review, ...)
  locale = application.user.locale.presence || 'en'

  rejection_reason = if proof_review.rejection_reason_code.present?
    reason = RejectionReason.resolve(
      code: proof_review.rejection_reason_code,
      proof_type: proof_review.proof_type, # returns "income" or "residency"
      locale: locale
    )
    reason&.body || proof_review.rejection_reason
  else
    proof_review.rejection_reason # "Other" / free text fallback
  end

  { rejection_reason: rejection_reason, ... }
end
```

`proof_review.proof_type` returns the enum string name (`"income"` or `"residency"`) — it maps directly to the `RejectionReason.proof_type` column.

---

## Part 3: JS Cleanup

**`rejection_form_controller.js`** (`app/javascript/controllers/forms/`) — already reads strings from ERB-supplied Stimulus values. No JS strings to remove. Once rejection reason strings move to the `RejectionReason` table, the ERB simply reads from the DB instead of hardcoded Ruby string literals — the Stimulus value wiring stays unchanged.

✅ **`document_proof_handler_controller.js`** (`app/javascript/controllers/users/`) — hardcoded reason/instruction maps were removed. UI now reads reason text from server-provided `data-reason-text` attributes.

---

## Part 4: Mailer Complexity ✅ Implemented

`ApplicationNotificationsMailer` remains large, but the highest-value structural cleanup has been completed without changing behavior.

### 1. Extract variable builder objects (highest impact) ✅

`proof_rejected` and `proof_approved` now use focused variable builder objects under `app/mailers/variables/`:

```ruby
# app/mailers/variables/proof_rejected.rb
# app/mailers/variables/proof_approved.rb
```

The rejection-reason resolution and `%{address}` interpolation logic now live in `Variables::ProofRejected`, keeping the mailer focused on orchestration. This follows the same object-composition direction as `NotificationComposer`.

### 2. Unify `handle_*_letter` into a single method ✅

Duplicated `handle_*_letter` methods were collapsed into a shared `handle_letter_preference` method:

```ruby
def handle_letter_preference(user, template_key, variables)
  generate_letter_if_preferred(user, "application_notifications_#{template_key}", variables)
end
```

### 3. Make `build_base_email_variables` explicit

`build_base_email_variables` remains explicit and is passed into variable builders from the call site, so the shared base payload is visible where each email is assembled.

### 4. Standardize the rescue/raise pattern ✅

Public mailer methods now use a shared `with_mailer_error_handling(context)` wrapper for consistent logging and re-raise behavior:

```ruby
def with_mailer_error_handling(context)
  yield
rescue StandardError => e
  Rails.logger.error("Mailer error (#{context}): #{e.message}\n#{e.backtrace.join("\n")}")
  raise
end
```

---

## Suggested Sequence

### Track A — Email Template Locale

1. ✅ Add `locale` column + `needs_sync` flag to `email_templates`; update unique index.
2. ✅ Update `find_email_template` to accept and fall back on locale.
3. ✅ Add `needs_sync` validation and `after_update` callbacks to `EmailTemplate`.
4. ✅ Surface `needs_sync` state in admin UI (index, show, edit); add `mark_synced` action.
5. ✅ Explicitly set `locale: 'en'` in all 36 seed files.
6. ✅ Seed ES variants of all existing templates (initially a copy of EN; translated later).
7. ✅ Side-by-side EN/ES edit UI (model already supports it).

### Track B — Rejection Reasons (unblocked for income/residency)

1. ✅ Create `rejection_reasons` table + `RejectionReason` model.
2. ✅ Seed initial records from the strings in `_modals.html.erb` (EN only to start).
3. ✅ Add `rejection_reason_code` to `proof_reviews`.
4. ✅ Update the proof review form to save the code on submission.
5. ✅ Update `build_proof_rejected_variables` to call `RejectionReason.resolve(...)`.
6. ✅ Remove `document_proof_handler_controller.js` hardcoded string maps; pass text from server.
7. ✅ Replace hardcoded admin modal rejection message bodies with `RejectionReason` DB lookups (shared helper + Stimulus data values unchanged).

### Track C — Medical Cert

Constituents do not receive email for medical cert rejections — intentional. Only the medical provider (the signer) is notified. The constituent sees status in their dashboard.

1. ✅ **Wire provider notification** — Provider fax/email notification fully implemented. See `docs/development/medical_provider_notification_implementation.md` for details.
   - `MedicalProviderNotifier` wired into `MedicalCertificationReviewer`
   - Fax-first delivery with automatic email fallback
   - Webhook-triggered blob cleanup
   - Error handling prevents notification failures from blocking rejections
2. ✅ Unify medical cert rejection storage on `proof_reviews` (proof_type: medical_certification) instead of `applications`; delegators on `Application` preserve backward compatibility.
3. ✅ Seed `RejectionReason` records for `proof_type: 'medical_certification'`.
4. ✅ Wire translation at send time for the provider email via `MedicalProviderMailer`.
   - `MedicalProviderMailer#certification_rejected` uses `RejectionReason.resolve` 
   - Locale-aware rejection reason lookup with English fallback
   - Metadata key (`'reason'`) matches `MedicalCertificationAttachmentService`

### Track D — Mailer cleanup (independent, do anytime)

1. ✅ Extract variable builder objects for `proof_rejected` and `proof_approved` first; migrate others opportunistically.
2. ✅ Unify `handle_*_letter` methods.
3. ✅ Standardize rescue/raise wrapper.

---

## What to Leave Alone

- `EmailTemplate` `%{variable}` interpolation — good as-is.
- `EmailTemplateRenderer` — small wrapper, leave it.
- `W9Review.rejection_reason_code` — already correct for its own domain.
- `NotificationComposer` — already clean and well-structured.
- `rejection_form_controller.js` Stimulus values wiring — already reads from ERB; no JS string duplication.
