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
| **ProofAttachmentService** | Upload / approve / reject | Unified for web, email, paper; handles blob validation |
| **Applications::MedicalCertificationService** | Request & track med certs | Updates status, sends provider emails via MedicalProviderMailer |
| **VoucherManagement** | Issue & redeem vouchers | Model concern; auto-assign when app approved AND medical cert approved |

---

## 2 · Creation Flows

### 2.1 Portal (Constituent)

1. **Auth → Dashboard → "Create Application"**  
2. **Form-based application** with autosave functionality.  
3. **Autosave**: UI changes trigger `app/javascript/controllers/forms/autosave_controller.js` which calls the backend `Applications::AutosaveService` via `constituent_portal/applications_controller#autosave_field`. This flow saves individual fields (excluding file inputs), returns validation errors inline, and updates the form action/URLs when a new draft `Application` is created.  
4. `Applications::ApplicationCreator` service:  
   * Uses `ApplicationForm` for validation → updates user attributes → creates/updates Application → attaches file uploads → logs events via `AuditEventService` + sends notifications via `NotificationService`.

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

* Admin timelines, user “Activity” tab, medical cert dashboard—all pull from **deduped event lists**.  
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
| Email   | Postmark + ActionMailer | Proof approved/rejected, account creation, cert requests |

**Note:** Only email notifications are currently implemented. The service uses a MAILER_MAP to route notification types to specific mailer methods.

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

## 6 · Medical Certification Flow

**Three Proof Types:** `income`, `residency`, and `medical_certification` (each with separate status enums)

1. `Applications::MedicalCertificationService.new(application:, actor:).request_certification`  
   * Updates `medical_certification_status` to 'requested', increments counter, creates audit events, sends email notification via MedicalProviderMailer.  
2. Provider replies via **multiple channels**:
   * **Email** → `MedicalCertificationMailbox` consumes → processes attachment and updates status to 'received'
   * **Fax** → **PARTIALLY IMPLEMENTED**: Outbound sending works (`FaxService` + `MedicalProviderNotifier`), but inbound processing requires manual admin scan/upload via admin interface → updates status to 'received'
   * **Snail Mail** → Admin scans and uploads via admin interface → updates status to 'received'
3. Admin can **approve/reject** via UI; auto-approve logic checks if all three proof types (income, residency, medical certification) are approved before voucher assignment.

**Key Difference:** Medical certification has its own workflow separate from income/residency proofs, with statuses: `not_requested`, `requested`, `received`, `approved`, `rejected`.

---

## 7 · Status Machine (Lite)

```
draft ─▶ in_progress ─▶ approved ─▶ (voucher auto-assigned via VoucherManagement concern)
      └▶ rejected
      └▶ awaiting_proof
      └▶ reminder_sent
      └▶ awaiting_dcf
      └▶ archived
```

*`approved` can be manual (admin) or automatic (via `ApplicationStatusManagement` concern when all requirements met).*  
All transitions create **ApplicationStatusChange** + audit events. Voucher auto-assignment happens in the `VoucherManagement` concern.

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

* Notifications for dependent apps go to **guardian**, not child.  
* **TODO:** Dependent contact: `email_strategy` & `phone_strategy` to be implemented to decide whether to clone guardian info or use unique fields.

---

## 9 · Vouchers

* Auto-assigned via `VoucherManagement#assign_voucher!` when application status is approved AND medical certification status is approved.  
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
| ActionMailbox | `/rails/action_mailbox` | Inbound email processing |
| Medical Cert Email | `MedicalCertificationMailbox` | Provider email replies |
| ActiveStorage   | background processing | File validation, metadata |
| ProofSubmissionMailbox | Email routing | Proof document submissions via email |

---

## 12 · How to Extend

* **New proof type?** Add enum to Application model, extend `ProofAttachmentService`, update mailbox routing in `determine_proof_type`, add ActiveStorage attachment.  
* **New notification?** Add to `NotificationService::MAILER_MAP` + template; call `NotificationService.create_and_deliver!`.  
* **New status?** Update enum in Application model, update auto-approval logic in VoucherManagement concern, add to front-end filters.  
* **New event?** Just log it with `AuditEventService.log`; `Applications::EventDeduplicationService` handles deduplication automatically.
* **Medical cert channel?** For automated processing, extend mailbox routing; for manual processing, enhance admin upload interface in `admin/applications#show`.

---

## 13 · Gotchas & Tips

1. **Always set `Current.paper_context`** in paper tests—or validations will fail.  
2. **Use `rails_request` keys** in JS to prevent duplicate AJAX hits on forms.  
3. **Phone numbers** must be normalised (`555-123-4567`) *before* uniqueness check.  
4. **Event floods** – if you log many similar events in <60 s, the dedup window ensures dashboards stay sane.  
5. **Voucher auto-assign** runs *after* approval callbacks—don’t forget when stubbing in specs.