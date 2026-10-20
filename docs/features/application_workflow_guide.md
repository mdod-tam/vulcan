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

Staff interfaces, including the evaluator and administrator portals, and staff-directed messages use English for v1. English/Spanish localization is limited to constituent portals and constituent-facing communications.

After approval, staff assign an active evaluator from the application's **Evaluation and Training Status** section, within the service window. Equipment fulfillment starts with an evaluation; voucher applications need one only when staff mark evaluator support as needed. Administrators can also be assigned as evaluators. [EvaluationManagement](../../app/models/concerns/evaluation_management.rb) owns assignment and reassignment.

The assignment sends a notice to the evaluator and appears in their requested queue at `/evaluators/dashboard`. The evaluator opens the record, contacts the applicant or the application's managing guardian, agrees on an appointment, and enters its future date/time and any location or scheduling notes. Scheduling and rescheduling record arrangements; the evaluator shares those arrangements directly with the applicant. Missing email or phone is shown as unavailable and does not prevent the evaluator assignment notice.

Assigned evaluators can open **View Applicant Information** for the applicant's contact details, address, disabilities, communication preferences, managing guardian, and alternate contact. Dependent contact choices resolve each field within that application's guardian context, with the contact owner identified. This summary excludes financial information, proof documents, and administrative controls. Administrators retain the full application view, including administrators acting as evaluators. Appointment and report mutations remain restricted to the assigned evaluator; standalone evaluation creation and information-request writes are not available through the evaluator portal.

Before report submission, the assigned evaluator can save **Working Notes** for outreach attempts and assessment preparation. This saves only that internal notes section; it leaves the appointment, lifecycle status, and report unchanged. Notes remain available to program staff and the replacement evaluator after reassignment. Working notes become read-only after submission; later additions use supplemental notes. Internal working notes are excluded from constituent confirmation messages.

After the appointment, the evaluator records the actual appointment date/time, location, internal **Working Notes**, and recommendations. Select recommended catalog products using checkboxes and describe any non-catalog products or other recommendation details in the text field; both can appear in one report. If nothing suitable was found, select **No suitable product was found** and explain why. This cannot be combined with catalog recommendations. Each product marked as tried requires a **Satisfied**, **Neutral**, or **Dissatisfied** rating. Direct assessments recommending catalog products require at least one trial; outside-catalog and no-suitable-product reports may have none. Other attendees are optional. Recommendation details are shared verbatim in the confirmation email or letter to the applicant or managing guardian; Working Notes stay internal. Program staff review outside-catalog recommendations and no-suitable-product decisions before deciding equipment fulfillment.

An assigned administrator can choose **Outside-specialist consultation** on a requested, scheduled, or confirmed evaluation. Record the actual consultation completion date, written source/context in report notes, and the recommendation outcome. This path does not require a future appointment, a planned date, a location, or claimed product trials; an existing planned appointment remains recorded, and known trials can still be recorded. The choice is restricted to the assigned administrator. An administrator viewing somebody else's report cannot submit it, and an ordinary evaluator cannot use the consultation exception.

The actual appointment time must not be in the future, even when the visit happened earlier than planned. Validation errors preserve entered fields, recommendation details, product selections and satisfaction ratings for correction and retry. A focused error summary links to the affected controls. Submission completes and locks the report, records its audit event, and requests a confirmation using the resolved delivery contact. The evaluator can subsequently add or update supplemental notes without changing the submitted report.

The three times have different meanings: `evaluation_date` is the planned appointment, `appointment_completed_at` is the evaluator-entered actual appointment, and `report_submitted_at` is captured by the server during successful report submission. Completed lists sort by report submission time. Historical report submission times are restored from their matching completion audit events when available; unknown actual or submission times retain that uncertainty rather than being inferred from the schedule or later edits.

Application messages use the shared [application contact context](../../app/services/applications/contact_context.rb). For a dependent, the application's managing guardian determines email versus letter preference; the selected email or mailing-address owner determines language. Secure-request links retain their explicit channel and persisted recipient snapshots. If the selected email route has no usable contact, delivery is recorded as not sent with a missing-recipient reason; it does not prevent report completion or send to another guardian or alternate contact.

The evaluator can cancel with a reason, mark a no-show after the scheduled time, or reschedule. Cancelled and no-show records appear in **Needs Follow-up**, where the assigned evaluator can arrange a future appointment. Within the service window, staff can open **Reassign Evaluator**, select the replacement and confirm the transfer in a dialog. Cancelling the dialog leaves the assignment unchanged. Practitioner choices show the staff member's account email alongside their name to distinguish people with the same name, with a record ID when no email is available. The appointment, outcome, notes, products, and history remain on the same record, both evaluator identities are audited, and the replacement is notified. The replacement receives portal access and confirms the arrangements directly with the applicant; the former evaluator loses access unless they retain administrator oversight permissions. Completed reports cannot be reassigned.

[Evaluation services](../../app/services/evaluations) lock the application before the evaluation and recheck approval, assignment, and lifecycle state before scheduling, rescheduling, or completing a report. A stale submission or appointment action cannot overwrite a completed report or act on a transferred assignment. Completed reports remain available after the application is archived. [Evaluator request tests](../../test/controllers/evaluator/evaluations_controller_test.rb), [access tests](../../test/controllers/evaluator/evaluation_access_test.rb), and [reassignment tests](../../test/models/evaluation_reassignment_test.rb) cover these boundaries.

## Equipment purchasing and shipment

Equipment purchasing preserves three separate facts: the submitted assessment recommendation, staff's current intended models and quantities, and each actual physical device. Equipment operations record fulfillment without changing application approval status.

Successful report completion initializes [EquipmentNeed](../../app/models/equipment_need.rb) rows in the report transaction: one unit per selected catalog model, or an intentional empty list for an outside-catalog/no-suitable-product outcome. It creates no physical devices. New reports can recommend only available catalog products; archived products remain available for recording past trials and remain in completed reports. The application's initialization marker prevents later reports from restoring removed needs. Staff use **Edit equipment needs** to change the quantity, set an old model to zero, and add a replacement catalog model. Zero rows and source-report references remain in history; these changes leave the submitted report intact. New quantities require an approved equipment application and an available catalog product. An outside-catalog model must first be added through catalog management.

An automatically initialized outside-catalog recommendation on an approved equipment application shows **Needs a catalog product** until staff save their purchasing decision with a reason. Staff can add an available catalog model or confirm that no new catalog device is needed by saving the empty list. That first confirmation is audited even when the list stays empty; repeating an unchanged save adds no duplicate decision event. A confirmed empty list shows **No equipment needed**. When the application is no longer eligible for purchasing, the unconfirmed recommendation retains a neutral **Outside-catalog recommendation** badge.

At `/admin/equipment`, the **Needs Ordering** tab combines remaining new-device quantities with individual previously ordered devices awaiting reorder. Staff select individual rows or all rows for an exact model within the current filters. Catalog Model and Vendor filters stay in the URL. Before ordering, Vendor means a vendor carrying that catalog model; afterward it means the awarded PO vendor. **Export for bids** exports the selection, or the current filtered set when nothing is selected, grouped by exact model and quantity without recipient addresses or device identifiers.

**Record Winning Bid & PO** reviews each model's new units and selected detached device IDs separately. Staff may reduce a new quantity, select a vendor and textual PO number with its actual sent date, or explicitly reuse an existing purchase order. One transaction creates/reuses the shared header, consumes needs, creates one [EquipmentItem](../../app/models/equipment_item.rb) per new unit, and relinks selected detached units using their existing IDs. A stale, unavailable, ineligible, or already-ordered selection rejects the entire operation. Refresh after a stale retry before reviewing again. The same normalized PO number cannot create another header for the same vendor.

**Ordered** means an active device has a current PO and no ship date. **Shipped** means it has a PO and valid actual ship date. Tracking alone does not ship a device. Each device has its own tracking, optional carrier, serial, and IMEI, even when identical models share an application or package. A ship date requires tracking, cannot precede the PO sent date, and cannot be in the future. Purchase orders show Awaiting Shipment, Partially Shipped, or Shipped based on their current devices; an empty order retains its history and displays **No equipment currently linked**.

Device and shared-header correction forms require a reason and current versions. Removing an unshipped device from its PO retains that device and returns it to Needs Ordering; it does not increase a remaining new-device quantity. A detached unshipped device can be withdrawn while retaining its history. Save device detail edits separately before detaching or withdrawing; combining them is rejected and retains the entered draft. Reordering reuses its ID. Shipped devices cannot be detached or withdrawn through this action; a mistaken ship date requires explicit confirmed correction. Shared changes and corrections involving shipped equipment show affected device/application counts and old/new values before confirmation, and recheck that impact before saving. Reviews expire after 30 minutes. An expired review keeps the entered draft and returns to **Review correction** so staff can review and confirm it again.

Active duplicate IMEIs and duplicate normalized serials for the same manufacturer/model identity are blocked, including duplicate catalog entries. Matching manufacturer/serial values on different models require acknowledgment and a reason. Tracking numbers may repeat across devices sharing a package. UPS, FedEx, and USPS selections with tracking provide a **Track package** link to an official carrier page in a new tab. Missing or unsupported carriers display tracking as text. MAT Vulcan does not fetch live carrier status or change shipment state when the link is opened.

The application's Equipment section shows the original recommendation, new devices still needed, and actual devices. Submitted reports, device records, and correction history remain readable after archival. Archived applications cannot receive new needs or order assignments; shipment and factual corrections remain available for existing equipment.

**Equipment by Type** counts active physical devices with a current PO, using each device's actual product and the PO sent date. Rerunning a historical period uses these current device and PO records. Purchasing needs contribute no units. Voucher reporting retains its existing behavior.

## Two things that bite

A status written directly leaves no `ApplicationStatusChange` row and fires none of the transition's follow-up work, so the application ends up in a state its own history cannot explain. Timeline deduplication does not compensate: it hides duplicate events from the display while both rows remain stored.

Portal and paper intake share the lifecycle but not the surrounding behavior, so a rule changed in one place is only half changed. [Portal creator tests](../../test/services/applications/application_creator_test.rb), [paper service tests](../../test/services/applications/paper_application_service_test.rb), [status-history tests](../../test/models/application_status_change_lifecycle_test.rb), and [voucher issuance tests](../../test/jobs/issue_initial_voucher_job_test.rb) cover the shared ground between them.
