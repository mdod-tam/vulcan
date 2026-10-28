# Security Reports and Audits

This is the review schedule for the [security baseline](../security/baseline_policy.md): what to check, how often, who does it, and what evidence to keep for the application, the infrastructure, and our providers.

The frequencies below are the project's baseline. Check them with the security owner against the agency's deadlines, the required assessment scope, and the named owners, and confirm any external submission dates and approval requirements before you rely on them.

## Schedule

| Frequency | Work | Responsible role | Evidence to retain |
| --- | --- | --- | --- |
| Each build/change | Review static analysis; maintain dependency and software bill of materials (SBOM) evidence. | Engineering / Security | Scan results, reviewed exceptions, SBOM, and remediation links. See current automation below. |
| Daily | Review security alerts and investigate suspicious access or privilege use. | Operations | Alert history, incident references, and follow-up. |
| Weekly | Triage dependency alerts and plan security patches. | Engineering | Triage decisions and deployment records. The project baseline calls for Ruby/Rails security updates and critical fixes within 30 days; stricter applicable deadlines take precedence. |
| Monthly | Review exception trends and confirm errors reach the configured monitoring service. | Operations | Representative errors, dashboard review, and assigned fixes. |
| Quarterly | Run internal/external vulnerability scans and review policy, control coverage, MFA, and access boundaries. | Engineering / Security | Dated scan reports, control assessment, remediation owners, and agreed deadlines. |
| Quarterly | Check centralized logs and alerts; exercise incident response and backup recovery. | Operations / Security | Retention checks, alert tests, tabletop notes, and successful restore evidence. |
| Every 90 days | Rotate operational secrets using the approved procedure. | DevOps | Rotation record, affected environments, and recovery checks. |
| Annually | Commission an independent penetration test across the application, infrastructure, and integrations. | Security | Assessment report, remediation decisions, and retest results. |
| Annually | Rotate encryption keys using a tested procedure; review audit-history integrity. | DevOps / Security | Tested key migration/restore, completed rotation record, and sampled history checks. See key handling below. |
| Annually and when approval scope changes | Refresh the policy assessment and applicable production approval package. | Compliance / Security | Reviewed requirements, assessment artifacts, unresolved conditions, and actual approval. |

The roles are assignments to make. When a review happens, record what was done and any exceptions, so an old scheduled date never stands in for a completed assessment.

## Current automation

- [CI](../../.github/workflows/ci.yml) runs Brakeman. Review the findings and rescan to confirm fixes.
- [Dependabot](../../.github/dependabot.yml) checks Bundler and GitHub Actions for updates every day.

Open hardening work is in the [project TODOs](../future_work/mat_vulcan_todos.md).

## Record the result

For each review, record its date, environment, scope, responsible person, result, and next due date. Link the report and any remediation work.

When a review produces a report, add its reference, the measured coverage, and the next review date to that control's `audit` block in [controls.yaml](../security/controls.yaml). Don't fill those in from a source-file pointer or a passing CI job. Neither tells you how much of a broader control is covered.

Keep reports and exports in an access-controlled evidence store. The catalog only points to them, so personal data, credentials, and sensitive findings stay out of the repo.

## Key handling and history

[PII encryption](../security/pii_encryption.md) lists the selected encrypted fields and key constraints. Editing Rails credentials isn't a rotation procedure by itself. Keep the previous keys you still need, check deterministic lookups and uniqueness, and show that current data and backups still read correctly before you retire the old keys.

For annual history checks, sample `Event` audit records, `ApplicationStatusChange` transitions, `ProofReview` decisions, and `Notification` communication history. The [audit guide](../features/audit_event_tracking.md) explains their different roles. Confirm coverage and retention for the workflows being assessed rather than assuming every model has the same history.

The [security baseline](../security/baseline_policy.md#before-production-approval) identifies the approval package. Track acceptance and open conditions with the agency. Approval comes from them, not from this checklist.
