# Paper Application Intake

Staff use paper intake to enter an application, identify its applicant, and attach or review documents in one workflow.

The resulting application then follows the shared approval and fulfillment rules.

[PaperApplicationsController](../../app/controllers/admin/paper_applications_controller.rb) handles the form, parameter normalization, identity-review response, and retry restoration.

[PaperApplicationService](../../app/services/applications/paper_application_service.rb) owns the final application write and its outcome.

## From form to saved application

1. Select an existing applicant or enter a new one. For a dependent, first select a guardian or finish **Save Guardian**.
2. Upload documents and submit. If identity needs review, the response retains uploads and presents the candidates. Select an eligible existing person or confirm different people with a rationale, then resubmit.
3. The writer locks and rechecks identity, eligibility, and relationships before saving the applicant, application, proofs, and completed identity decisions together.
4. After a confirmed save, run follow-up communications and workflow reconciliation. Failures here produce warnings rather than an invitation to create the same application again.

Guardian quick-create is a separate JSON write through [PaperGuardianQuickCreateService](../../app/services/applications/paper_guardian_quick_create_service.rb). The final application submission requires its returned guardian ID or an existing selection. A later application rollback does not undo that earlier guardian save.

## Applicants and identity review

| Branch | Important boundary |
| --- | --- |
| Existing adult | Recheck application eligibility and the selected contact-verification/update choice before reuse. |
| Existing dependent | Reuse only an eligible dependent already related to the chosen guardian. This flow does not edit the dependent's name or DOB. |
| New adult | Create a new constituent; an exact email/phone collision must not silently select a different person. Phone-only and address-only intake are supported. |
| New dependent | [GuardianDependentManagementService](../../app/services/applications/guardian_dependent_management_service.rb) creates the dependent and relationship, applying the chosen email, phone, and address strategies. |

An existing dependent's name and DOB render as on-file text on both initial selection and retry. The form submits `dependent_id`, without hidden copies of those identity fields. Contact details, address, and preferences remain editable. Paper intake owns those updates; changing an existing person's identity needs a separate authorized workflow with duplicate checks and audit history.

[PaperIdentityReview](../../app/services/applications/paper_identity_review.rb) owns matching, candidate presentation, selectable roles, and signed decisions. Exact contact collisions block new-record creation; possible name/DOB/address matches require staff to choose an eligible existing person or confirm that they are different people.

Writers recompute under [PaperIdentityCreationLock](../../app/services/applications/paper_identity_creation_lock.rb) and participant row locks. [PaperIdentityReviewReceipt](../../app/services/applications/paper_identity_review_receipt.rb) binds the actor, role/context, identity, and displayed candidates through keyed digests and expires after 30 minutes. Changed facts or an expired receipt require another review. Dependent decisions also depend on the guardian, relationship, and contact choices. Server-side eligibility checks still apply after a picker selection.

[CreateService.record_paper_decision!](../../app/services/duplicate_review_cases/create_service.rb) records completed `paper_intake` cases for all three roles. Keep-separate records one resolved case per new-person/candidate pair; existing selection records `resolved_selected` / `existing_person_selected` without a second user. Cases and their audit events commit with the application and proofs, or with the separate guardian save. Clear creation needs no identity case. `paper_identity_no_match_confirmed` is historical evidence with no new writer.

## Proof choices

| Document | Form actions |
| --- | --- |
| Income, residency, ID | `upload_only`, `accept`, or `reject` |
| Disability certification | `upload_only`, `approved`, or `rejected` |

Uploading or approving requires a document. Rejecting requires a reason, plus custom text for `other`, but no file. **None Provided** means rejection with the `none_provided` reason.

Regular proofs use [ProofAttachmentService](../../app/services/proof_attachment_service.rb). Disability certification uses [MedicalCertificationAttachmentService](../../app/services/medical_certification_attachment_service.rb), with provider rejection follow-up routed through the certification reviewer when provider contact is available. See [proof review](../features/proof_review_process_guide.md).

`PaperApplicationService` scopes `Current.paper_context` around its writes and clears it afterward; guardian quick-create sets it in [Admin::UsersController#create](../../app/controllers/admin/users_controller.rb) and resets `Current` in `ensure`. Both are entry points that genuinely own a paper-intake request. Set anywhere else, the flag relaxes profile and proof validation for whatever happens to run next — it is scoped state, not a validation or callback bypass.

## Save outcomes and retries

The controller uses the service result and `commit_confirmed?`, not the in-memory record's `persisted?` flag.

| Result | Response |
| --- | --- |
| `true`, confirmed commit | Open the application, including any follow-up warning. |
| `true`, unconfirmed commit | Open the applications list with instructions to check before re-entering it. No further follow-up work runs against the uncertain record. |
| `false` | The application transaction failed; re-render the form with the service error. |

A callback can raise after the database commits. The create service checks durable existence before classifying that exception, and does not rerun a partly completed callback.

If a concurrent write causes a unique-contact collision while inserting a new dependent, the application transaction rolls back. `PaperApplicationService` then recomputes identity review and returns a contact refusal staff can act on, without retrying the insert or exposing database constraint text.

### Retry restoration

Two allowlists define the contract: `permitted_paper_params` is what the controller accepts, `build_submitted_params` is what a re-render puts back. A field in the first and not the second is silent data loss on retry — accepted for processing, gone from the form — so each accepted field has either a restoration source or a stated reason for exclusion.

Three distinctions survive the round trip or the retry lies about what staff entered: a deliberate blank is not an omission, `false` is not absent, and a fresh-form default is not a submitted choice.

| Field group | Restoration rule |
| --- | --- |
| Applicant, application, and guardian fields | Rebuild the appropriate records from submitted values, including address/state and alternate-contact relationship. Disabled duplicate fieldsets must not replace the active branch's values. |
| Disability answers | Five disability flags belong to the applicant; `self_certify_disability` belongs to the application, although submitted under `applicant_attributes`. |
| Applicant branch and selected people | Restore IDs, visible names, and existing/new mode together. Infer the branch when disabled radios are omitted; a selected dependent submits no name. |
| Dependent contact and relationship choices | Restore own-contact fields, email/phone/address strategies, and relationship type. Preserve unchecked choices through their hidden false-value inputs. |
| Proof instructions and section flags | Restore all four document actions, rejection reasons/custom text, `no_medical_provider_information`, and `no_income_information`. |
| Uploads | Restore completed uploads through signed blob IDs and filenames in `PROOF_BLOB_FIELDS`. Native file inputs cannot be refilled; replace missing or invalid blobs when the restored action requires a file. |

Retained blobs must exist, be unattached, and be less than seven days old. Successful replacement leaves one current signed ID; removal or rejection clears it, while failed replacement keeps the prior upload. [CleanupUnattachedUploadsJob](../../app/jobs/cleanup_unattached_uploads_job.rb) purges older unattached blobs daily, rechecking under the same blob lock used by intake. Attached application documents are outside that cleanup.

Identity-review retries render the current candidates, receipt, rationale, and selected candidate. Stale facts require renewed review, and an existing self-applicant selection requires contact verification.

**Save Guardian** failures stay in the page's JSON flow. A final submission carrying unsaved guardian fields is refused and restores those non-file values so staff can save or select a guardian.

The two layers catch different failures. Request and view tests answer whether a value came back and whether blank, false, and absent stayed distinct. Browser tests are the only place picker changes, branch switching, unchecked and disabled controls, upload replacement, and Stimulus reconnection after a retry behave realistically — a request test posting an explicit `"0"` cannot reproduce a browser that omits the field entirely.

Unbalanced markup in one branch of a conditional is worth watching for specifically: a stray closing tag lets the browser reparent everything after it, which can move a section outside the `<form>` and leave its controller unable to see its own targets, with no error anywhere.

## Deployment and recovery

[Migration 20260917004500](../../db/migrate/20260917004500_add_inline_paper_review_outcomes.rb) is irreversible, even before any selection is recorded. Apply it before starting the new workers. Recovery must roll forward with a release that understands `resolved_selected` (status `5`); do not roll back the migration, deploy an older status model, or rewrite completed decisions. During recovery, pause paper intake, preserve the database and audit history, and verify an existing selection and a new intake before reopening.

Older open forms may still call `POST /admin/paper_applications/identity_review`. Its authenticated, uncached response only resumes native submission: it does no lookup and issues no receipt. The create action ignores legacy decisions, recomputes identity, and preserves multipart uploads as unattached blobs on refusal, under the same seven-day retention policy. Keep the adapter until those tabs are closed and access logs show no calls for seven consecutive days; then remove its route and action together. Multipart retry preservation remains useful independently.

## Follow-up and fulfillment

After a confirmed create, the service separately attempts the creation audit, notifications, proof-delivery checks, and a provider-info request when provider details are missing. A failed step produces a named warning and a best-effort `application_post_creation_step_failed` audit event. Reconciliation failures also surface to staff.

Account-created notices apply to eligible email-backed users created during intake or marked by a recent quick-create. `send_account_created_notice?` checks the current `vouchers_enabled` flag; it does not check the application's saved fulfillment type. These notices confirm receipt; they contain no temporary password or sign-in link. Account help uses the existing account-access flow.

Creation stamps fulfillment and income-proof requirements from the feature state. Approval reconciliation works for equipment and voucher applications; only voucher applications enter automatic voucher issuance. See the [application workflow](../features/application_workflow_guide.md).

## Where to check changes

- [Paper service tests](../../test/services/applications/paper_application_service_test.rb): transaction outcomes and follow-up failures.
- [Controller tests](../../test/controllers/admin/paper_applications_controller_test.rb): parameter handling and restored values.
- [Identity review tests](../../test/services/applications/paper_identity_review_test.rb): candidates and decisions.
- [Paper rollback](../../test/system/admin/paper_application_rollback_test.rb) and [identity browser tests](../../test/system/admin/paper_identity_review_test.rb): retry interactions and review choices.
