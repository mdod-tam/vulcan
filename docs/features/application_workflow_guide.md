# Application Workflow

An `Application` holds one constituent's application to receive accessible telecommunications equipment and/or a voucher.

After submission, staff review the proofs and disability certification that came with it.

Approval then moves the application toward issuance of equipment or of a voucher.

Portal and paper intake share the same application model and lifecycle methods, but differ in their identity checks, form behavior, and follow-up messages.

## How applications enter the system

| Path | Owner and behavior |
| --- | --- |
| Portal draft/autosave | [AutosaveService](../../app/services/applications/autosave_service.rb) saves individual non-file fields and can create a draft. |
| Portal save/submission | [ApplicationCreator](../../app/services/applications/application_creator.rb) validates the form, locks/rechecks participants and eligibility, saves applicant/application changes and attachments, then records history. Final submission moves the draft to `in_progress`. |
| Staff paper intake | [PaperApplicationService](../../app/services/applications/paper_application_service.rb) coordinates applicant selection/creation, proofs, the application write, and follow-up. Guardian quick-create is a separate step; see [paper intake](../development/paper_application_architecture.md). |

Portal final submission is blocked while the applicant is the subject of an open `registration_soft_match` review case. Draft saves and autosave can continue. The submission gate runs before applicant/application mutation; draft ownership, waiting-period rules, and conflicting applications are also checked under lock.

`ApplicationCreator` does not send its own notifications. Paper intake has explicit post-save communications and warns when they fail. Avoid assuming the two entry points have identical side effects.

## Draft autosave and reporting

[AutosaveService](../../app/services/applications/autosave_service.rb) saves allowlisted fields and records the last successful field in `applications.last_visited_step`. Despite its name, this is an attribute such as `household_size`, not a form page. The marker uses `update_column`, so its write skips model validations and callbacks. Failed or unsupported field saves do not advance it; file uploads use a separate flow.

The admin **Pain Point Analysis** report at `/admin/application_analytics/pain_points` uses [Application.pain_point_analysis](../../app/models/application.rb) to count current drafts by that attribute, excluding blank markers. These counts are a clue for investigation: there is no inactivity cutoff, and they do not prove abandonment or explain why someone stopped.

The [autosave controller tests](../../test/controllers/constituent_portal/applications_controller_autosave_test.rb) and [report tests](../../test/controllers/admin/application_analytics_controller_test.rb) cover the server side; browser behavior is in [JavaScript architecture](../development/javascript_architecture.md#autosave-as-a-representative-interaction).

## Status and approval

[Application#transition_status!](../../app/models/application.rb) owns lifecycle changes: the status update, the status-history row, and the `application_status_changed` audit call happen together in one transaction. Transitioning to the status the application already has returns early and writes nothing.

| Status | Meaning |
| --- | --- |
| `draft` | The constituent is still preparing the application. |
| `in_progress` | Submitted and being processed. |
| `awaiting_proof`, `reminder_sent` | Waiting for documents or recording a reminder. |
| `awaiting_dcf` | Waiting for the disability certification form. |
| `approved`, `rejected`, `archived` | Approved, declined, or retained as historical work. |

These are available states, not a promise that every transition between them is allowed by every workflow.

[Application#reconcile_workflow_state!](../../app/models/concerns/application_status_management.rb) reevaluates progress after document work:

- Approved residency and ID proofs, plus income proof when required, satisfy the regular proof requirements.
- When those proofs are approved and certification is outstanding, reconciliation can move the application to `awaiting_dcf` and request certification.
- When required proofs and disability certification are approved, reconciliation can approve the application.
- Already approved, rejected, or archived applications are left alone.

Fulfillment type and whether income proof is required are stamped at creation from feature settings. Use the application's stored requirements for its subsequent review.

## Documents have two review paths

**Income, residency, and ID:** [ProofAttachmentService](../../app/services/proof_attachment_service.rb) and [ProofReview](../../app/models/proof_review.rb) own attachment/review behavior. Approval requires a file; rejection can record a missing document. Rejection delivery goes through `Applications::RequestProofResubmission`, which issues a secure upload request. A delivery failure does not erase the saved review.

**Disability certification:** provider requests, secure uploads, staff uploads, and DocuSeal have their own services. Certification progresses through `not_requested`, `requested`, `received`, `approved`, or `rejected`. Receipt or a completed signature is separate from approval. Incoming fax/postal documents require staff upload.

See [proof review](proof_review_process_guide.md) and [DocuSeal integration](../development/docuseal_integration_guide.md) for those workflows.

## Guardians, communication, and history

For a dependent application, `application.user` is the dependent and `managing_guardian` identifies the responsible guardian. A submitted ID alone does not authorize a relationship. Contact ownership determines where a message can go; see [guardian relationships](../development/guardian_relationship_system.md).

Communications may create notification history, email, printable letters, or workflow-specific SMS. Some actions, including individual proof approval, are intentionally record-only. Start with [notifications](notifications.md) rather than adding a mailer call at each lifecycle step.

The application timeline combines several record types. It filters and deduplicates them for display; it is not the complete raw audit dataset. See [audit events](audit_event_tracking.md).

## Fulfillment settings

At creation, [Application#stamp_workflow_defaults!](../../app/models/application.rb) saves the fulfillment type and income-proof requirement. With `vouchers_enabled` on, it selects voucher fulfillment and no income-proof requirement; with it off, it selects equipment fulfillment and requires income proof.

[FeatureFlag.income_proof_required?](../../app/models/feature_flag.rb) is the inverse of `vouchers_enabled`, not a separate feature-flag row. Approval uses the application's saved requirement, so changing the flag does not rewrite existing applications.

## Voucher fulfillment

An approved transition for a voucher application queues [IssueInitialVoucherJob](../../app/jobs/issue_initial_voucher_job.rb) after commit. [VoucherManagement](../../app/models/concerns/voucher_management.rb) checks the feature flag, eligibility, and existing voucher before issuance.

Equipment applications do not create vouchers. Vendor redemption is a separate workflow through `Vouchers::RedemptionService`; see [voucher controls](../security/voucher_security_controls.md).

## Two things that bite

A status written directly leaves no `ApplicationStatusChange` row and fires none of the transition's follow-up work, so the application ends up in a state its own history cannot explain. Timeline deduplication does not compensate: it hides duplicate events from the display while both rows remain stored.

Portal and paper intake share the lifecycle but not the surrounding behavior, so a rule changed in one place is only half changed. [Portal creator tests](../../test/services/applications/application_creator_test.rb), [paper service tests](../../test/services/applications/paper_application_service_test.rb), [status-history tests](../../test/models/application_status_change_lifecycle_test.rb), and [voucher issuance tests](../../test/jobs/issue_initial_voucher_job_test.rb) cover the shared ground between them.
