# Current Application Features

An at-a-glance yet detailed map of MAT Vulcan's major feature sets as of December 2025.

---

## 1 · Application Lifecycle

| Status | Description | Next Steps |
|--------|-------------|------------|
| `draft` | Constituent working on application | Submit for review |
| `in_progress` | Submitted, being processed | Proof review, medical cert |
| `awaiting_proof` | Waiting for income/residency proofs | Constituent uploads proofs |
| `awaiting_dcf` | Waiting for disability certification form | Medical provider submits DCF |
| `approved` | Application approved | Voucher assignment |
| `rejected` | Application denied | Constituent may reapply |
| `archived` | Historical record | — |

**Auto-approval** triggers when ALL requirements met:
- Income proof approved
- Residency proof approved  
- Medical certification approved

---

## 2 · Proof Management System

### 2.1 Proof Types

| Type | Status Enum | Attachment |
|------|-------------|------------|
| Income | `income_proof_status` | `income_proof` |
| Residency | `residency_proof_status` | `residency_proof` |
| Medical Cert | `medical_certification_status` | `medical_certification` |

### 2.2 ProofAttachmentService

Single entry point for all proof uploads (web, paper, email):

```ruby
ProofAttachmentService.attach_proof(
  application:  app,
  proof_type:   :income,            # Symbol, not string
  blob_or_file: file,
  status:       :approved,          # or :not_reviewed
  admin:        current_admin,      # nil for user upload
  submission_method: :paper,
  metadata:     { ip_address: request.remote_ip }
)
```

**Key features:**
- Supports files OR signed blob IDs
- Auto-creates audit events
- Honors `Current.paper_context` for paper flows
- Returns hash with `success`, `error`, `duration_ms`, `blob_size`

### 2.3 Proof Review

Approvals handled via `ProofReview` model with callbacks:
```ruby
ProofReview.create!(
  application: app,
  admin: admin,
  proof_type: :income,
  status: :approved
)
```

For paper rejections without file:
```ruby
ProofAttachmentService.reject_proof_without_attachment(
  application: app,
  proof_type: :income,
  admin: admin,
  reason: 'Document unclear'
)
```

---

## 3 · Medical Certification System

### 3.1 Status Flow

```
not_requested → requested → received → approved/rejected
```

### 3.2 Channels

| Channel | Implementation | Status |
|---------|---------------|--------|
| **Email** | `MedicalCertificationMailbox` (Action Mailbox) | ✅ Automated |
| **DocuSeal** | `DocumentSigning::SubmissionService` | ✅ Production-ready |
| **Fax** | `FaxService` + `MedicalProviderNotifier` | ⚠️ Outbound only |
| **Mail** | Admin scan/upload | ✅ Manual process |

### 3.3 DocuSeal Integration (Digital Signing)

Separate tracking for e-signature workflow:

| `document_signing_status` | Meaning |
|---------------------------|---------|
| `not_sent` | No request sent |
| `sent` | Request sent to provider |
| `opened` | Provider opened signing link |
| `signed` | Provider completed signing |
| `declined` | Provider declined |

**Workflow**: `document_signing_status: signed` + admin review → `medical_certification_status: approved`

### 3.4 Request Flow

```ruby
# Send via email
service = Applications::MedicalCertificationService.new(
  application: app,
  actor: admin
)
result = service.request_certification

# Send via DocuSeal
result = DocumentSigning::SubmissionService.new(
  application: app,
  actor: admin,
  service: 'docuseal'
).call
```

---

## 4 · Guardian & Dependent System

### 4.1 Relationship Model

```ruby
GuardianRelationship.create!(
  guardian_user: guardian,
  dependent_user: dependent,
  relationship_type: 'Parent'  # or 'Legal Guardian', etc.
)
```

### 4.2 Application Context

| Helper | Returns |
|--------|---------|
| `application.for_dependent?` | `true` if `managing_guardian_id` present |
| `application.managing_guardian` | Guardian user managing this app |
| `application.editable_by?(user)` | Can user edit this application? |
| `application.guardian_relationship_type` | Relationship type string |

### 4.3 Authorization Scopes

```ruby
Application.editable_by(user)     # Apps user can edit
Application.accessible_by(user)   # Apps user can view
Application.managed_by(guardian)  # Apps guardian manages
```

**Key rule**: Notifications for dependent apps go to **managing guardian**, not dependent.

---

## 5 · Voucher System

### 5.1 Auto-Assignment

Triggered when `all_requirements_met?`:
- Income proof approved
- Residency proof approved
- Medical certification approved

```ruby
# VoucherManagement concern handles assignment
application.assign_voucher!
```

### 5.2 Voucher Lifecycle

```
issued → active → redeemed/expired/cancelled
```

### 5.3 Vendor Redemption

1. Vendor enters voucher code
2. System verifies constituent DOB
3. Vendor processes redemption
4. `VoucherTransaction` created
5. Invoice generated for vendor

---

## 6 · Training & Evaluation

### 6.1 Training Sessions

| Status | Description |
|--------|-------------|
| `requested` | Training requested |
| `scheduled` | Date/time set |
| `confirmed` | Trainer confirmed |
| `completed` | Training done |
| `cancelled` | Session cancelled |

**Services**: `TrainingSessions::ScheduleService`, `CompleteService`, etc.

### 6.2 Evaluations

Similar workflow with evaluator assignment and completion tracking.

---

## 7 · Notification System

### 7.1 Channels

| Channel | Implementation |
|---------|---------------|
| Email | `NotificationService` → ActionMailer → Postmark |
| In-app | Rails flash messages |
| Print | `PrintQueueItem` for paper letters |

### 7.2 Creating Notifications

```ruby
NotificationService.create_and_deliver!(
  type: 'proof_approved',
  recipient: user,
  actor: admin,
  notifiable: application,
  metadata: { proof_type: 'income' },
  channel: :email
)
```

### 7.3 Email Tracking

| Component | Purpose |
|-----------|---------|
| `Notification.message_id` | Postmark message ID |
| `Notification.delivery_status` | delivered/opened/error |
| `UpdateEmailStatusJob` | Polls Postmark for status |
| `PostmarkEmailTracker` | API wrapper |

---

## 8 · Audit & Events

### 8.1 Event Creation

```ruby
AuditEventService.log(
  action: 'proof_approved',
  actor: admin,
  auditable: application,
  metadata: { proof_type: 'income' }
)
```

### 8.2 Deduplication

`Applications::EventDeduplicationService` ensures clean timelines:
- 1-minute buckets
- Priority: StatusChange > Event > Notification
- Used by dashboards, audit logs, timelines

---

## 9 · Admin Tools

| Task | Location |
|------|----------|
| Manage applications | `/admin/applications` |
| Request medical cert | Application show page |
| Send DocuSeal request | Application show page |
| Review proofs | Application show page |
| Bulk approve/reject | Applications index |
| Print queue | `/admin/print_queue` |
| Email templates | `/admin/email_templates` |
| User management | `/admin/users` |
| Voucher management | `/admin/vouchers` |
| Vendor management | `/admin/vendors` |
| Pain point analysis | `/admin/application_analytics/pain_points` |

---

## 10 · Portals

| Portal | Users | Key Features |
|--------|-------|--------------|
| **Constituent** | Applicants | Submit/track applications, upload proofs |
| **Admin** | Administrators | Full management, reports, dashboards |
| **Vendor** | Vendors | Voucher redemption, transactions, invoices |
| **Evaluator** | Evaluators | Evaluation scheduling, completion |
| **Trainer** | Trainers | Training session management |

---

## 11 · Troubleshooting

| Issue | Check |
|-------|-------|
| File upload fails | S3 creds, file type/size, transaction rollbacks |
| Email not delivered | `POSTMARK_API_TOKEN`, `UpdateEmailStatusJob` logs |
| Med cert stuck | Provider delivery logs, Notification status |
| Guardian can't see app | `GuardianRelationship` exists, `managing_guardian_id` set |
| DocuSeal not working | Credentials, webhook configuration |
| Voucher not assigned | Check all 3 proof statuses are `approved` |

---

## 12 · Background Jobs

| Job | Purpose |
|-----|---------|
| `MedicalCertificationEmailJob` | Send medical cert requests |
| `UpdateEmailStatusJob` | Poll Postmark for delivery status |
| `CheckVoucherExpirationJob` | Process expired vouchers |
| `GenerateVendorInvoicesJob` | Create vendor invoices |
| `ProofAttachmentMetricsJob` | Monitor attachment failures |
| `NotifyAdminsJob` | Batch admin notifications |

---

## 13 · Roadmap Highlights

**High Priority:**
- Inbound fax automation (Twilio webhook)
- Dependent contact strategies (email/phone source)

**Medium Priority:**
- Live chat with transcript capture
- Custom report builder
- Notification analytics dashboard

**Lower Priority:**
- Duplicate detection with merge workflows
- Doc AI validation
- Advanced analytics