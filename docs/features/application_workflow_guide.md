# Application Workflow

An `Application` holds one constituent's application to receive accessible telecommunications equipment and/or a voucher.

After submission, staff review the proofs and disability certification that came with it.

Approval then moves the application toward issuance of equipment or of a voucher.

Portal and paper intake share the same application model and lifecycle methods, but differ in their identity checks, form behavior, and follow-up messages.

## How applications enter the system

| Path | Owner and behavior |
| --- | --- |
| Portal draft/autosave | [AutosaveService](../../app/services/applications/autosave_service.rb) resumes or creates the actor's draft and saves individual non-file fields. |
| Portal save/submission | [ApplicationCreator](../../app/services/applications/application_creator.rb) validates the form, locks/rechecks participants and eligibility, saves applicant/application changes and attachments, then records history. Final submission moves the draft to `in_progress`. |
| Staff paper intake | [PaperApplicationService](../../app/services/applications/paper_application_service.rb) coordinates applicant selection/creation, proofs, the application write, and follow-up. Guardian quick-create is a separate step; see [paper intake](../development/paper_application_architecture.md). |

Portal final submission is blocked while the applicant is the subject of an open `registration_soft_match` review case. Draft saves and autosave can continue. The submission gate runs before applicant/application mutation; draft ownership, waiting-period rules, and conflicting applications are also checked under lock.

`ApplicationCreator` does not send its own notifications. Paper intake has explicit post-save communications and warns when they fail. Avoid assuming the two entry points have identical side effects.

## Draft autosave and reporting

[AutosaveService](../../app/services/applications/autosave_service.rb) resumes or creates a draft using the same actor/applicant rule as the portal form and full Save. It saves allowlisted fields and records the last successful field in `applications.last_visited_step`. Despite its name, this is an attribute such as `household_size`, not a form page. Application-field saves update the marker with `update_column`, which skips validations and callbacks. Disability-field saves persist it with `save!(validate: false)`, which skips validations but runs callbacks. Failed or unsupported field saves do not advance it; file uploads use a separate flow.

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
- When those proofs are approved and certification is outstanding, reconciliation can move the application to `awaiting_dcf`. It does not request certification: staff send the request from the application page, which shows certification as Not Requested until then.
- When required proofs and disability certification are approved, reconciliation can approve the application.
- Already approved, rejected, or archived applications are left alone.

Fulfillment type and whether income proof is required are stamped at creation from feature settings. Use the application's stored requirements for its subsequent review.

## Documents have two review paths

**Income, residency, and ID:** [ProofAttachmentService](../../app/services/proof_attachment_service.rb) and [ProofReview](../../app/models/proof_review.rb) own attachment/review behavior. Approval requires a file; rejection can record a missing document. Rejection delivery goes through `Applications::RequestProofResubmission`, which issues a secure upload request. A delivery failure does not erase the saved review.

**Disability certification:** provider requests, secure uploads, staff uploads, and DocuSeal have their own services. Certification progresses through `not_requested`, `requested`, `received`, `approved`, or `rejected`. Receipt or a completed signature is separate from approval. Incoming fax/postal documents require staff upload. Staff upload is unavailable while a certification awaits review (`received`) or is approved, so it cannot replace one; it returns once a certification is rejected. `MedicalCertificationAttachmentService.attach_certification` checks this under the same application lock a provider submission takes, so a submission that arrives mid-request is not displaced. Secure provider forms follow their own request rules.

See [proof review](proof_review_process_guide.md) and [DocuSeal integration](../development/docuseal_integration_guide.md) for those workflows.

## Guardians, communication, and history

For a dependent application, `application.user` is the dependent and `managing_guardian` identifies the responsible guardian. A submitted ID alone does not authorize a relationship. Contact ownership determines where a message can go; see [guardian relationships](../development/guardian_relationship_system.md).

Communications may create notification history, email, printable letters, or workflow-specific SMS. Some actions, including individual proof approval, are intentionally record-only. Start with [notifications](notifications.md) rather than adding a mailer call at each lifecycle step.

The application timeline combines several record types. It filters and deduplicates them for display; it is not the complete raw audit dataset. See [audit events](audit_event_tracking.md).

## Program policies

[`Policy`](../../app/models/policy.rb) stores income thresholds, waiting periods, training limits, request throttles, secure-link timing, and voucher amounts. Initialize these with `bin/rails db:seed_policies` as part of [baseline setup](../infrastructure/setup_and_maintenance.md#baseline-seeds). The task applies the checked-in defaults, including updates when existing values differ.

Inspect the configured values from the command line:

```bash
bin/rails runner 'pp Policy.order(:key).pluck(:key, :value).to_h'
```

Routine changes go through `/admin/policies`. For a console update, set `policy.updated_by` to the responsible administrator before `policy.update!(value: ...)` so the `PolicyChange` records the operator. When changing initialization defaults, keep [the production task](../../lib/tasks/seed_policies.rake) and `create_policies` in [the demo seed](../../db/seeds.rb) aligned.

## Fulfillment settings

At creation, [Application#stamp_workflow_defaults!](../../app/models/application.rb) saves the fulfillment type and income-proof requirement. With `vouchers_enabled` on, it selects voucher fulfillment and no income-proof requirement; with it off, it selects equipment fulfillment and requires income proof.

[FeatureFlag.income_proof_required?](../../app/models/feature_flag.rb) is the inverse of `vouchers_enabled`, not a separate feature-flag row. Approval uses the application's saved requirement, so changing the flag does not rewrite existing applications.

`bin/rails db:seed_feature_flags` initializes a missing `vouchers_enabled` flag to disabled. Inspect it with `bin/rails features:list`; use `bin/rails 'features:enable[vouchers_enabled]'` or `bin/rails 'features:disable[vouchers_enabled]'` when deliberately changing fulfillment mode.

## Voucher fulfillment

An approved transition for a voucher application queues [IssueInitialVoucherJob](../../app/jobs/issue_initial_voucher_job.rb) after commit. [VoucherManagement](../../app/models/concerns/voucher_management.rb) checks the feature flag, eligibility, and existing voucher before issuance.

Equipment applications do not create vouchers. Vendor redemption is a separate workflow through `Vouchers::RedemptionService`; see [voucher controls](../security/voucher_security_controls.md).

## Evaluator workflow

After approval, staff assign an active evaluator from the application's **Evaluation and Training Status** section, within the service window. Equipment fulfillment starts with an evaluation; voucher applications need one only when staff mark evaluator support as needed. Administrators can also be assigned as evaluators. [EvaluationManagement](../../app/models/concerns/evaluation_management.rb) owns assignment and reassignment.

The assignment sends a notice to the evaluator and appears in their requested queue at `/evaluators/dashboard`. The evaluator opens the record, contacts the applicant or the application's managing guardian, agrees on an appointment, and enters its future date/time and any location or scheduling notes. Scheduling and rescheduling record arrangements; the evaluator shares those arrangements directly with the applicant. Missing email or phone is shown as unavailable and does not prevent the evaluator assignment notice.

Assigned evaluators can open **View Applicant Information** for the applicant's contact details, address, disabilities, communication preferences, managing guardian, and alternate contact. Dependent contact choices resolve each field within that application's guardian context, with the contact owner identified. This summary excludes financial information, proof documents, and administrative controls. Administrators retain the full application view, including administrators acting as evaluators. Appointment and report mutations remain restricted to the assigned evaluator; standalone evaluation creation and information-request writes are not available through the evaluator portal.

Before report submission, the assigned evaluator can save **Working Notes** for outreach attempts and assessment preparation. This saves only that internal notes section; it leaves the appointment, lifecycle status, and report unchanged. Notes remain available to program staff and the replacement evaluator after reassignment. Working notes become read-only after submission; later additions use supplemental notes. Internal working notes are excluded from constituent confirmation messages.

After the appointment, the evaluator records the actual appointment date/time, location, report notes, and one recommendation outcome. **Catalog products** requires at least one product tried and one recommended product. **Outside the catalog** and **No suitable product** require written details and can have no catalog products tried or recommended. Any catalog devices tried during those assessments can still be recorded. Recommendation details may also accompany catalog recommendations; other attendees are optional. Program staff review outside-catalog recommendations and no-suitable-product outcomes before deciding equipment fulfillment.

The actual appointment time must not be in the future, even when the visit happened earlier than planned. Validation errors preserve entered fields, outcome choice, recommendation details and product selections for correction and retry. A focused error summary links to the affected controls. Submission completes and locks the report, records its audit event, and requests a confirmation using the resolved delivery contact. The evaluator can subsequently add or update supplemental notes without changing the submitted report.

The three times have different meanings: `evaluation_date` is the planned appointment, `appointment_completed_at` is the evaluator-entered actual appointment, and `report_submitted_at` is captured by the server during successful report submission. Completed lists sort by report submission time. Historical report submission times are restored from their matching completion audit events when available; unknown actual or submission times retain that uncertainty rather than being inferred from the schedule or later edits.

Application messages use the shared [application contact context](../../app/services/applications/contact_context.rb). For a dependent, the application's managing guardian determines email versus letter preference; the selected email or mailing-address owner determines language. Secure-request links retain their explicit channel and persisted recipient snapshots. If the selected email route has no usable contact, delivery is recorded as not sent with a missing-recipient reason; it does not prevent report completion or send to another guardian or alternate contact.

The evaluator can cancel with a reason, mark a no-show after the scheduled time, or reschedule. Cancelled and no-show records appear in **Needs Follow-up**, where the assigned evaluator can arrange a future appointment. Within the service window, staff can use **Reassign Evaluator** for unfinished work: the appointment, outcome, notes, products, and history remain on the same record, both evaluator identities are audited, and the replacement is notified. The replacement receives portal access and confirms the arrangements directly with the applicant; the former evaluator loses access unless they retain administrator oversight permissions. Completed reports cannot be reassigned.

[Evaluation services](../../app/services/evaluations) lock the application before the evaluation and recheck assignment and lifecycle state before writing. A stale submission or appointment action cannot overwrite a completed report or act on a transferred assignment. [Evaluator request tests](../../test/controllers/evaluator/evaluations_controller_test.rb), [access tests](../../test/controllers/evaluator/evaluation_access_test.rb), and [reassignment tests](../../test/models/evaluation_reassignment_test.rb) cover these boundaries.

## Two things that bite

A status written directly leaves no `ApplicationStatusChange` row and fires none of the transition's follow-up work, so the application ends up in a state its own history cannot explain. Timeline deduplication does not compensate: it hides duplicate events from the display while both rows remain stored.

Portal and paper intake share the lifecycle but not the surrounding behavior, so a rule changed in one place is only half changed. [Portal creator tests](../../test/services/applications/application_creator_test.rb), [paper service tests](../../test/services/applications/paper_application_service_test.rb), [status-history tests](../../test/models/application_status_change_lifecycle_test.rb), and [voucher issuance tests](../../test/jobs/issue_initial_voucher_job_test.rb) cover the shared ground between them.
