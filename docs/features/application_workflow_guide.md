# MAT Vulcan Application Workflow Guide

---

## Quick Map

```text
Portal User ─────▶ Applications::ApplicationCreator ──────┐
                                                          │        ▾
Admin  ──▶ Applications::PaperApplicationService ──▶ App   │  Applications::EventDeduplicationService
                                                          │        ▾
                       ProofAttachmentService ←───────────┘  AuditEventService & NotificationService
                            ▲     ▲         ▲
                            │     │         └─ Applications::MedicalCertificationService
                            │     └── VoucherManagement (concern)
                            └── GuardianRelationship
```

All flows converge on **one Application record**, so every downstream service (events, proofs, notifications, vouchers) works the same no matter how the app started.

---

## 1 · Core Building Blocks

| Component | Purpose | Notes |
|-----------|---------|-------|
| **Applications::ApplicationCreator** | Portal self-service "happy path" | Runs in DB TX; fires events & notifications |
| **Applications::PaperApplicationService** | Admin data-entry path | Sets `Current.paper_context` to bypass online-only validations |
| **Applications::EventDeduplicationService** | 1-min window, priority pick | Used by audit views, dashboards, certification timelines |
| **NotificationService** | Email notifications | Postmark integration; uses MAILER_MAP for routing |
| **ProofAttachmentService** | Upload / approve / reject | Unified for portal, secure form, and paper proof handling; handles blob validation |
| **Applications::MedicalCertificationService** | Request and track disability certifications | Updates status and sends provider emails |
| **VoucherManagement** | Issue & redeem vouchers | Model concern used by `IssueInitialVoucherJob` after approval commits |

---

## 2 · Creation Flows

### 2.1 Portal (Constituent)

1. **Auth → Dashboard → "Create Application"**  
2. **Form-based application** with autosave functionality.  
3. **Autosave**: UI changes trigger `app/javascript/controllers/forms/autosave_controller.js` which calls the backend `Applications::AutosaveService` via `constituent_portal/applications_controller#autosave_field`. This flow saves individual fields (excluding file inputs), returns validation errors inline, and updates the form action/URLs when a new draft `Application` is created. It locks/revalidates the guardian/applicant user rows before the application so a concurrent duplicate merge either includes the saved draft or makes the stale autosave fail.
4. `Applications::ApplicationCreator` service:
   * Uses `ApplicationForm` for validation → locks/revalidates participants → updates user attributes → creates/updates Application → attaches file uploads → logs events via `AuditEventService` + sends notifications via `NotificationService`.
   * Owns the only routed final portal submission path through `ApplicationsController#update`; the former unused member `submit` endpoint is removed.

### 2.2 Paper (Admin)

1. **Admin → Paper Apps → New**  
2. Dynamic form (guardian search / create, proof accept with file; reject without file).  
3. Wrap all logic with:

```ruby
Current.paper_context = true
begin
  process_paper_application # uses Applications::PaperApplicationService
ensure
  Current.paper_context = nil
end
```

4. Same downstream services as portal flow → single behaviour set.

---

## 3 · Event System (Why you care)

* Admin timelines, user “Activity” tab, and disability certification dashboard all pull from **deduped event lists**.
* Dedup key: `[fingerprint, minute_bucket]` → pick highest priority (StatusChange > Event > Notification).

```ruby
service = Applications::EventDeduplicationService.new
events  = service.deduplicate(raw_events)
```

When adding a new event type, **just log it**—the service handles dedup for you.

---

## 4 · Notifications in Plain English

| Channel | Stack | Typical Use |
|---------|-------|-------------|
| Email   | Postmark + ActionMailer | Account creation, status notifications, certification requests |
| Letter  | Text templates + print queue | Account creation and certification requests when postal delivery is selected |

**Note:** Proof rejection delivery uses secure proof resubmission request services. Those services create tracking records and then attempt delivery through the selected contact channel; if delivery fails, the review can still persist and the admin is alerted.

Create and deliver:

```ruby
NotificationService.create_and_deliver!(
  type: 'proof_rejected',
  recipient: application.user,
  actor: admin,
  notifiable: review,
  metadata: { template_variables: { ... } }
)
```

Delivery metadata (bounce, spam status) is stored for audit & retries via Postmark webhooks.

---

## 5 · Proof Review in 3 Calls

```ruby
# Upload (user or admin)
ProofAttachmentService.attach_proof(...)
# Review (approve or reject) - handled by ProofReview model callbacks
ProofReview.create!(application: app, admin: admin, proof_type: :income, status: :approved)
# Or use the service for rejection without attachment
ProofAttachmentService.reject_proof_without_attachment(...)
```

Approvals require an attachment; only rejections may proceed without a file. The ProofReview model handles post-review actions via callbacks.

---

## 6 · Disability Certification Flow

**Requirements:** reviewable proofs are `income` when required, `residency`, and `id`. Disability certification is tracked separately through `medical_certification_status`.

1. `Applications::MedicalCertificationService.new(application:, actor:).request_certification`  
   * Updates `medical_certification_status` to `requested`, increments counters, creates audit events, and sends the provider request through the configured delivery path.
2. Provider certification is received via **multiple channels**:
   * **Secure upload link** → `Applications::RequestCertificationUpload` issues a `MedicalProviderSecureRequestForm`; `Applications::SubmitCertificationUpload` attaches the file and updates status to 'received'
   * **DocuSeal** → `DocumentSigning::SubmissionService` manages the e-signature flow and webhook completion
   * **Fax** → **PARTIALLY IMPLEMENTED**: Outbound sending works (`FaxService` + `MedicalProviderNotifier`), but received faxes require manual admin scan/upload via admin interface → updates status to 'received'
   * **Snail Mail** → Admin scans and uploads via admin interface → updates status to 'received'
3. Admin can **approve/reject** via UI; workflow reconciliation checks that required proofs and disability certification are approved before the application can finish approval.

**Key Difference:** Disability certification has its own workflow separate from income, residency, and ID proof review, with statuses: `not_requested`, `requested`, `received`, `approved`, `rejected`.

---

## 7 · Status Machine (Lite)

```
draft ─▶ in_progress ─▶ approved ─▶ (IssueInitialVoucherJob auto-issues voucher when eligible)
      └▶ rejected
      └▶ awaiting_proof
      └▶ reminder_sent
      └▶ awaiting_dcf
      └▶ archived
```

*`approved` can be manual (admin) or automatic (via `ApplicationStatusManagement` concern when all requirements met).*  
All transitions create **ApplicationStatusChange** + audit events. Voucher auto-issuance is enqueued after an approved transition commits.

---

## 8 · Guardian / Dependent Cheat Sheet

```ruby
GuardianRelationship.create!(
  guardian_user:  guardian,
  dependent_user: dependent,
  relationship_type: 'Parent'
)
application.user              = dependent
application.managing_guardian = guardian
```

* Notifications for dependent apps use the effective contact strategy for the dependent/guardian relationship.
* Paper intake already supports `email_strategy`, `phone_strategy`, and `address_strategy` for dependent contact handling.

---

## 9 · Vouchers

* Only voucher-fulfillment applications auto-issue vouchers. `IssueInitialVoucherJob` runs after a real `transition_status!(:approved)` commit when `FeatureFlag.enabled?(:vouchers_enabled)`, `fulfillment_type: voucher`, required proofs, and disability certification are all approved. Equipment-fulfillment applications do not create vouchers.
* Stored in `vouchers` table with configurable expiry period (Policy-based).  
* Vendor portal handles voucher redemption which creates `VoucherTransaction` records.  
* Value calculated based on constituent's disability types and stored in `initial_value` field.

---

## 10 · Admin Toolkit Highlights

* **Applications::FilterService** handles index search & facets.  
* Dashboard metrics loaded via `DashboardMetricsLoading` concern with optimized queries.  
* Bulk ops (`batch_approve`, `batch_reject`) are handled by `admin/applications_controller#batch_approve` and `admin/applications_controller#batch_reject`.  
* **Applications::AuditLogBuilder** + **Applications::EventDeduplicationService** = fast, deduped history for show view.

---

## 11 · Integration Hooks

| Service | Endpoint / Job | Purpose |
|---------|----------------|---------|
| Postmark | `/webhooks/email_events` | Delivery / bounce / spam tracking |
| Secure certification upload | `SecureCertificationFormsController` | Provider certification file upload |
| Secure proof resubmission | `SecureProofFormsController` | Constituent proof resubmission upload |
| DocuSeal | `Webhooks::DocusealController` | Document signing completion |
| ActiveStorage   | background processing | File validation, metadata |

---

## 12 · How to Extend

* **New proof type?** Add enum to Application model, extend `ProofAttachmentService`, add the secure form/request path if constituents must resubmit it, and add ActiveStorage attachment.
* **New notification?** Add to `NotificationService::MAILER_MAP` + template; call `NotificationService.create_and_deliver!`.  
* **New status?** Update enum in Application model, update auto-approval logic in `ApplicationStatusManagement`, add to front-end filters.  
* **New event?** Just log it with `AuditEventService.log`; `Applications::EventDeduplicationService` handles deduplication automatically.
* **Disability certification channel?** Prefer a typed secure upload or provider integration path; for manual processing, enhance admin upload interface in `admin/applications#show`.

---

## 13 · Gotchas & Tips

1. **Always set `Current.paper_context`** in paper tests—or validations will fail.  
2. **Use `rails_request` keys** in JS to prevent duplicate AJAX hits on forms.  
3. **Phone numbers** must be normalised (`555-123-4567`) *before* uniqueness check.  
4. **Event floods** – if you log many similar events in <60 s, the dedup window ensures dashboards stay sane.  
5. **Voucher auto-issue** runs in `IssueInitialVoucherJob` after approval commits—don’t forget when stubbing in specs.
