# Current Application Features

An at-a-glance yet detailed map of MAT Vulcan’s major feature sets as of Dec 2025.

---

## 1 · Medical Certification System

| Step | Actor | Key Service / Model |
|------|-------|---------------------|
| 1. User requests cert | Constituent | **Application** (`medical_certification_status`) |
| 2. Admin sends request | Admin | `Applications::MedicalCertificationService` → `Notification` |
| 3. Provider returns doc | Provider | **Multiple channels**: Email (`MedicalCertificationMailbox`), Fax (**PARTIAL** - outbound only), Snail Mail (admin scan/upload) |
| 4. Admin reviews doc | Admin | Admin UI → approve/reject via `ApplicationsController#show` |
| 5. App auto- or manual-approves | System | Auto-approval when all proof types approved |

*Provider channels*: **Email** (automated), **Fax** (outbound automated, inbound admin processed), **Snail Mail** (admin processed).  
*Audit*: every action logs `ApplicationStatusChange`, `Event`, and `Notification`.

---

## 2 · Proof Attachment System

Single entry point: **`ProofAttachmentService`**. Handles uploads from web, paper, email, and fax with identical logic:

```ruby
ProofAttachmentService.attach_proof(
  application: app,
  proof_type:  'income',
  blob_or_file: file,
  status:      :not_reviewed,
  admin:       current_admin,            # nil when user upload
  metadata:    { submission_method: :web, ip_address: request.remote_ip }
)
```

*Transactions wrap attach → status update → `ProofSubmissionAudit`.  
*Resubmission & rate limits* enforced via policy objects.  
`ProofReviewService` drives approve / reject UI.

Monitoring: `ProofAttachmentMetricsJob` raises alerts if > 5 % failures (≥ 5 per 24 h).

---

## 3 · Email Tracking

| Component | Purpose |
|-----------|---------|
| `Notification` columns | `message_id`, `delivery_status`, `delivered_at`, `opened_at`, `metadata` |
| `MedicalCertificationEmailJob` | Sends mail, captures Postmark message ID |
| `UpdateEmailStatusJob` | Polls Postmark; updates status; reschedules until final |
| `PostmarkEmailTracker` | Thin wrapper around Postmark API |

UI: certification-history modal shows color-coded status, open device & location.

Add tracking to any mail by: **(1)** create `Notification`, **(2)** pass it to mailer, **(3)** enqueue `UpdateEmailStatusJob`.

---

## 4 · Guardian Relationship System

*Explicit* `GuardianRelationship` records; dependent contact flexibility.

```ruby
GuardianRelationship.create!(
  guardian_user: guardian,
  dependent_user: dependent,
  relationship_type: 'Parent'
)
```

| Helper | Meaning |
|--------|---------|
| `user.guardian? / dependent?` | quick role checks |
| `application.for_dependent?` | `managing_guardian_id` present? |
| `user.effective_email / phone` | picks dependent-specific or fallback |

**Notification routing**: goes to `managing_guardian` when `for_dependent?`.

---

## 5 · Event Deduplication

`Applications::EventDeduplicationService` = single source of truth.

```ruby
deduped = EventDeduplicationService.new.deduplicate(events)
```

*Key ideas*: 1-minute buckets, fingerprint + priority (StatusChange > Event > Notification).  
Used by dashboards, audit logs, medical cert timeline.

---

## 6 · Cross-Feature Glue

* Proof uploads feed medical-cert workflow (providers can email proofs).
* Email tracking monitors provider requests.
* Guardian context persists through **every** service (notifications, audits, voucher issuance).
* All flows share audit & error-handling patterns.

---

## 7 · Administrator Cheat Sheet

| Task | Where |
|------|-------|
| Request med cert | Application ▶ “Request Medical Certification” |
| Review cert | Application ▶ Upload / Approve / Reject |
| Review proofs | Application ▶ Proofs tab |
| Bulk approve apps | Admin ▶ Applications ▶ select ▶ “Approve” |
| Print letters | Admin ▶ Print Queue |
| Check inbound emails | `/rails/conductor/action_mailbox/inbound_emails` |

---

## 8 · Troubleshooting Quick Hits

| Issue | Check |
|-------|-------|
| File upload fails | S3 creds, file type/size validation, transaction rollbacks |
| Email tracking stalled | `POSTMARK_API_TOKEN`, message stream, `UpdateEmailStatusJob` logs |
| Med cert stuck “requested” | Provider delivery (fax/email) logs, Notification status |
| Guardian can’t see app | Ensure `GuardianRelationship` exists & `managing_guardian_id` set |

---

## 9 · Roadmap Highlights

* **High**: Direct-to-S3 uploads + virus scan  
* **Medium**: Provider portal, auto-reminder emails  
* **Low**: Doc AI validation, digital signatures, advanced analytics