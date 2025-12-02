# MAT Vulcan Documentation Hub

A roadmap to **every doc, guide, and reference** in the repository—so devs and AI helpers can jump straight to what they need.

---

## 1 · Quick Start

| Step | Where to look | Why |
|------|---------------|-----|
| **1. Feature Overview** | `current_application_features.md` | Know what the app does right now |
| **2. Test & Debug** | `development/testing_and_debugging_guide.md` | Local setup, CurrentAttributes patterns, debugger tips |
| **3. Service Patterns** | `development/service_architecture.md` | Understand how business logic is encapsulated |
| **4. Application Flow** | `features/application_workflow_guide.md` | End-to-end application lifecycle |

> **Tip:** Search the **development/** folder first for any "how do I…?" question—most implementation guides live there.

---

## 2 · Folder Map

### 📂 development/

Deep-dive, code-facing docs for contributors.

| File | Highlights |
|------|------------|
| `testing_and_debugging_guide.md` | Test execution, CurrentAttributes in tests, debugger tips |
| `service_architecture.md` | All service objects, `BaseService` patterns, `EventDeduplicationService` |
| `guardian_relationship_system.md` | Model graph, `GuardianRelationship`, managing guardian logic |
| `javascript_architecture.md` | Stimulus target-first pattern, `rails_request` service, base controllers |
| `paper_application_architecture.md` | Admin paper-form flow, `Current.paper_context` bypass |
| `user_management_features.md` | Phone/email dedup, `data-testid` naming, factory recipes |
| `docuseal_integration_guide.md` | Digital document signing for medical certifications |

### 📂 features/

Spec-level docs for discrete user stories and workflows.

| File | Highlights |
|------|------------|
| `application_workflow_guide.md` | End-to-end application lifecycle, service integration |
| `proof_review_process_guide.md` | Proof submission, review, and approval workflow |
| `notifications.md` | Email notifications, Rails flash patterns, template system |
| `audit_event_tracking.md` | Central logging, deduplication, event timeline |
| `application_pain_point_tracking.md` | Draft drop-off analysis |
| `email_uniqueness_for_dependents.md` | Dependent email handling |

### 📂 infrastructure/

Ops-level references.

| File | Highlights |
|------|------------|
| `email_system.md` | Template DB workflow, inbound Action Mailbox, Postmark |
| `active_storage_s3_setup.md` | S3 file storage configuration |

### 📂 security/

Security controls and authentication.

| File | Highlights |
|------|------------|
| `authentication_system.md` | 2FA implementation (WebAuthn, TOTP, SMS) |
| `voucher_security_controls.md` | Voucher redemption security |
| `controls.yaml` | Security control definitions |
| `pii_encryption.md` | Field-level encryption |

### 📂 compliance/

Regulatory documentation.

| File | Highlights |
|------|------------|
| `required_reports_audits.md` | Compliance requirements |

### 📂 future_work/

Living backlog and architectural planning.

| File | Highlights |
|------|------------|
| `mat_vulcan_todos.md` | Prioritized task list with control IDs |

### 📂 ui_components/

Design-system documentation.

| File | Highlights |
|------|------------|
| `password_visibility_toggle.md` | Password field UI component |

---

## 3 · Doc-Hunting Tips for AI Assistants

| Need | Where to search |
|------|-----------------|
| "How does X feature work?" | `current_application_features.md` → specific file in **features/** |
| "Which service owns Y?" | `development/service_architecture.md` |
| "What JS pattern should I follow?" | `development/javascript_architecture.md` |
| "Where's the email config?" | `infrastructure/email_system.md` |
| "How does auth work?" | `security/authentication_system.md` |
| "Upcoming tasks?" | `future_work/mat_vulcan_todos.md` |
| "How to test X?" | `development/testing_and_debugging_guide.md` |

Naming is grep-friendly: *feature names* mirror folder/file names, so `"guardian_relationship_system"` appears exactly once per folder.

---

## 4 · Key Concepts

| Concept | Definition |
|---------|------------|
| **Current.paper_context** | Thread-local flag to bypass online-only validations in paper flows |
| **Managing Guardian** | The guardian responsible for a dependent's application |
| **EventDeduplicationService** | Removes duplicate events in 1-minute buckets for clean timelines |
| **Proof Types** | `income`, `residency`, `medical_certification` (each tracked separately) |
| **Document Signing Status** | Separate from medical certification status; tracks e-signature workflow |
| **BaseService::Result** | Standard result object with `success?`, `message`, `data` |

---

## 5 · User Types (STI)

| Type | Namespace | Primary Role |
|------|-----------|--------------|
| Constituent | `Users::Constituent` | Applies for vouchers |
| Administrator | `Users::Administrator` | Manages applications, users, vendors |
| Evaluator | `Users::Evaluator` | Conducts evaluations |
| Trainer | `Users::Trainer` | Provides training sessions |
| Vendor | `Users::Vendor` | Redeems vouchers, manages transactions |
| Medical Provider | `Users::MedicalProvider` | Provides medical certifications |
