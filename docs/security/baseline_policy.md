# Security Baseline

This policy covers MAT Vulcan's code, infrastructure, environments, and providers handling agency data.

It states the security requirements and the evidence needed to assess them.

[controls.yaml](controls.yaml) maps stable control IDs to implementation files and remaining verification needs.

Its source descriptions are not an audit result or proof of deployed configuration.

## Policy authority

Confirm applicable requirements with the agency security owner using Maryland DoIT's [Cybersecurity & Privacy Policy Suite](https://doit.maryland.gov/policies/ci/Pages/default.aspx) and [transitional governing documents](https://doit.maryland.gov/policies/ci/cpp/Pages/Cybersecurity-and-Privacy-Policy-Transitional-Governing-Policy-Documents.aspx). The catalog preserves older DoIT/NIST mappings for traceability; they need review against current standards.

The requirements below retain the project's baseline. Confirm external deadlines, approval scope, and any stricter obligations before relying on them for a release. A checked-in policy is not authorization to operate.

## Application controls

| Area | Current implementation and boundary |
| --- | --- |
| Authentication | BCrypt passwords, an eight-character minimum, account lockout, and public-auth throttling. MFA is required for administrators, evaluators, trainers, and vendors; constituents can opt in. See [authentication](authentication_system.md). |
| Sessions | Signed session-token cookies with HttpOnly and production Secure flags. Sessions expire after 24 hours by default; the previously stated 30-minute idle-timeout target is not implemented by that expiry. |
| Personal data | Selected fields use Active Record Encryption. Stable keys and safe logging are essential; see the [field inventory and key constraints](pii_encryption.md). |
| Requests and access | Base-controller CSRF protection, role checks, scoped record access, and purpose-specific token/throttle paths. Public endpoints need their own authentication or token contract. |
| HTTPS and browser controls | Production enables `force_ssl`. Verify TLS versions and response headers at the deployment edge. The CSP initializer is commented out, so it does not establish an active application policy. |
| Uploads | Proof uploads have content-type and size validation. The catalog does not establish malware-scanning coverage. |
| History and errors | Domain workflows write audit events; production logs to stdout and disables local exception detail pages. Log storage, retention, and alerting require deployment evidence. |

These descriptions identify code to inspect. They do not certify every entry point or environment.

## Operational requirements

The [reports and audits checklist](../compliance/required_reports_audits.md#schedule) owns review frequencies, responsible roles, and completion evidence. Keep scheduling changes there.

| Requirement | Evidence to maintain |
| --- | --- |
| Inventory software, infrastructure, providers, and data flows; classify the data handled | Current inventory and data-flow map, including a check against the State's prohibited technologies. |
| Store secrets in encrypted credentials or a managed key service; keep plaintext secrets out of Git | Access controls, key custody, and recovery procedure. Persistent data must never depend on temporary encryption keys. |
| Protect data in transit and at rest | TLS 1.2+ configuration, storage/backup encryption settings, and reviewed field coverage. Rails `force_ssl` alone does not prove protocol or storage settings. |
| Rotate secrets and encryption keys using a tested migration/recovery procedure | Rotation records and successful data/backup recovery. Automation and completion require operational evidence. |
| Generate a software bill of materials (SBOM) and scan dependencies in CI | Build artifacts and dependency-scan reports. These are requirements, not established current CI behavior. |
| Triage dependency alerts, apply security updates, and remediate vulnerabilities | Dated scan/assessment reports, remediation owners, and deployment or retest evidence; follow the checklist's deadlines and stricter applicable requirements. |
| Centralize security logs for at least one year, with a 400-day project retention target; alert on authentication spikes and privilege misuse | Retention configuration, representative searches, and alert tests. |
| Review controls and exercise incident response and backup recovery | Review record, tabletop results, and successful restore evidence. |

See [current automation](../compliance/required_reports_audits.md#current-automation) for the checks provided by CI and the operational evidence still needed.

## Open policy checks

- Reconcile the password and MFA policy with applicable external-user requirements. The cited [2021 external-user guidance](https://doit.maryland.gov/policies/ci/Pages/standards-and-guidance-for-authentication-of-external-users.aspx) specifies a 12-character password minimum and sensitivity-based authentication requirements; the application's eight-character minimum is not evidence of compliance.
- Verify the stated BCrypt cost target of at least 12, session-idle timeout, and session replacement behavior before marking those controls complete.
- Confirm deployed TLS, headers/CSP, upload scanning, centralized logging, and retention. Source files alone do not establish hosting or provider controls.
- Replace unknown audit results with real reports and review dates. The catalog's null evidence fields mean unverified.

## Before production approval

The security owner should maintain the applicable approval package: system security plan, risk assessment and remediation plan, security assessment report, backup/contingency plan, incident response plan, change-control evidence, and Statement of Compliance.

Use [compliance reporting](../compliance/required_reports_audits.md) as a work list, then confirm the required package and approval authority with the agency. Record actual approval and unresolved conditions before launch; do not infer approval duration, hosting suitability, or compliance from this guide.

Update the catalog when an implementation changes. Follow the review schedule and replace expired plans or placeholder evidence with current, attributable records.
