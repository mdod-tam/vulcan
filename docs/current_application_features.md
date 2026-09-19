# Current Application Features

This Ruby on Rails application manages the lifecycle of applications submitted for accessible telecommunications assistance.

That lifecycle runs from intake through document review, disability certification, fulfillment, and any related training or evaluation.

This page is a feature map.

The linked guides explain how each workflow works.

## Applications and identity

Constituents can prepare drafts, autosave form fields, submit applications, upload proofs, and follow their status. Guardians can act for dependents they manage. Staff can enter paper applications, review documents, and handle follow-up.

[The application workflow](features/application_workflow_guide.md) explains the shared lifecycle. [Paper intake](development/paper_application_architecture.md) covers staff-assisted creation, identity decisions, direct uploads, and recovery when a save or follow-up step fails.

Two rules shape submission:

- Eligibility checks cover the applicant, application ownership, conflicting applications, and the waiting-period policy.
- An open `registration_soft_match` case blocks the **applicant's final submission**, while drafting and autosave remain available. The block follows the dependent applicant, not the guardian acting for them, and remains until no matching open case remains. Other case sources and the review badge alone do not control this gate.

The portal displays the restriction, but the writer rechecks under lock. See [user management](development/user_management_features.md#what-blocks-application-submission) for identity-review decisions and account/contact rules.

## Documents and approval

| Feature | What people can do |
| --- | --- |
| Income, residency, and ID proofs | Submit files; staff approve or reject them and request replacements through secure upload links. Income proof is conditional on the application's stored requirement. |
| Disability certification | Request provider documentation, collect it through secure upload or DocuSeal, upload scanned documents, review the result, or print a DCF. |
| Automatic approval | Reconcile the application after document work: approved residency, ID, required income proof, and disability certification can lead to approval. |

Proof review and disability certification are separate workflows. DocuSeal completion means a document was signed, not that staff approved the certification. Incoming fax/postal documents require staff upload; inbound email is not a live collection path.

A saved proof rejection survives a failed resubmission-request delivery, with a warning for staff. See [proof review](features/proof_review_process_guide.md) and [DocuSeal integration](development/docuseal_integration_guide.md).

## Guardians and dependents

The dependent owns the application; its managing guardian has responsibility for managing it. Existing relationships and application ownership control access. Email, phone, and postal delivery can have different contact owners.

[Guardian relationships](development/guardian_relationship_system.md) explains those boundaries and how contact strategies affect intake and messages.

## Fulfillment, training, and evaluation

| Feature | Current behavior and owner |
| --- | --- |
| Equipment or voucher fulfillment | The voucher flag selects both fulfillment type and the inverse income-proof requirement at creation; see [fulfillment settings](features/application_workflow_guide.md#fulfillment-settings). |
| Vouchers | When enabled, approval of a voucher application queues issuance after commit. Issuance rechecks eligibility and existing vouchers. Vendors verify the applicant and redeem value; see [voucher controls](security/voucher_security_controls.md). |
| Vendor invoices | [Invoice generation](../app/services/invoices/generation_service.rb) groups completed, uninvoiced voucher transactions into vendor invoices. |
| Training | Staff assign trainers within the service window and session quota. Trainers schedule, complete, cancel, or arrange follow-up through [training services](../app/services/training_sessions). |
| Evaluation | Staff assign evaluators within the service window; evaluators schedule visits and submit reports through [evaluation services](../app/services/evaluations). |

[TrainingManagement](../app/models/concerns/training_management.rb) and [EvaluationManagement](../app/models/concerns/evaluation_management.rb) own assignment rules. Equipment applications do not automatically receive vouchers.

Training sessions and evaluations share the [status vocabulary](../app/models/concerns/status_management.rb): `requested`, `scheduled`, `confirmed`, `completed`, `cancelled`, and `no_show`. `rescheduled` remains for legacy/display compatibility; current rescheduling services set `scheduled` and record a reschedule event.

## Communication and history

[Notifications](features/notifications.md) record communication and may send email or create printable letters. Some actions, including individual proof approval, are intentionally record-only. Rails flash messages provide immediate feedback; selected workflows send SMS directly.

Staff can edit localized templates and manage the print queue. [Email and letters](infrastructure/email_system.md) covers template syntax, secure-request delivery, Postmark, and tracking limits.

[Audit history](features/audit_event_tracking.md) records business actions separately from communications. Application timelines combine several record types and deduplicate their display, so the timeline is not the complete raw audit dataset.

## Main work areas

| Area | Starting route |
| --- | --- |
| Staff application queues and review | `/admin/applications` |
| Paper intake | `/admin/paper_applications/new` |
| Users and duplicate review | `/admin/users`, `/admin/duplicate_reviews` |
| Templates and printable documents | `/admin/email_templates`, `/admin/print_queue` |
| Vendors, vouchers, and invoices | `/admin/vendors`, `/admin/vouchers`, `/admin/invoices` |
| Constituent applications | `/constituent_portal/applications` |
| Vendor redemption and invoices | `/vendor_portal/vouchers`, `/vendor_portal/invoices` |
| Evaluator and trainer work | `/evaluators/evaluations`, `/trainers/training_sessions` |
| Draft drop-off analysis | `/admin/application_analytics/pain_points` |

Routes depend on role and feature availability. For implementation work, continue with [service architecture](development/service_architecture.md), [JavaScript architecture](development/javascript_architecture.md), or [testing and debugging](development/testing_and_debugging_guide.md).
