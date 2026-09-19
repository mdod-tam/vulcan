# Security Reports and Audits

This checklist owns the operational schedule for the [security baseline](../security/baseline_policy.md).

It covers application, infrastructure, and provider evidence.

A scheduled task is not evidence that a control is implemented or an assessment passed.

The frequencies below retain the project's stated baseline. Confirm applicable agency deadlines, required assessment scope, and named owners with the security owner.

External submission dates and approval requirements need confirmation before use.

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

These are responsibilities to assign, not evidence that each named role is staffed or each system is deployed. Record actual completion and exceptions rather than carrying an old scheduled date forward as a passed assessment.

## Current automation

- [CI](../../.github/workflows/ci.yml) runs Brakeman. Review findings and verify fixes with a fresh scan.
- [Dependabot](../../.github/dependabot.yml) checks Bundler dependencies and GitHub Actions daily; review and deployment remain separate work.
- The checked-in workflows do not run `bundler-audit`, generate an SBOM, or validate the controls YAML. Those items need a defined process and evidence before being marked complete.
- Centralized logging, alerting, penetration testing, and key rotation require operational evidence outside the source tree.

## Record the result

For each review, record its date, environment, scope, responsible person, result, and next due date. Link the report and any remediation work.

Update [controls.yaml](../security/controls.yaml) where the control has `audit.report`, `audit.coverage`, and `audit.next_review_due` fields. Leave unknown results explicit; a source-file pointer or passing CI job does not establish a broader control's coverage.

Keep reports and exports in an access-controlled evidence store. The catalog can hold report references without copying personal data, credentials, or sensitive findings into the repository.

## Key handling and history

[PII encryption](../security/pii_encryption.md) lists the selected encrypted fields and key constraints. Editing Rails credentials alone is not a rotation procedure: retain the required previous keys, check deterministic lookups and uniqueness, and prove that current data and backups remain readable before retiring old keys.

For annual history checks, sample `Event` audit records, `ApplicationStatusChange` transitions, `ProofReview` decisions, and `Notification` communication history. The [audit guide](../features/audit_event_tracking.md) explains their different roles. Confirm coverage and retention for the workflows being assessed rather than assuming every model has the same history.

The [security baseline](../security/baseline_policy.md#before-production-approval) identifies the approval package. Track acceptance and unresolved conditions with the agency; this checklist does not grant approval.
