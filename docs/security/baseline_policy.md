# Security Baseline

This policy covers MAT Vulcan's code, infrastructure, environments, and providers that handle agency data.

It states the security requirements and the evidence needed to assess them.

[controls.yaml](controls.yaml) maps stable control IDs to implementation files and lists what still needs verification.

Its source descriptions are not an audit result. They are not proof of deployed configuration.

## Policy authority

Confirm the applicable requirements with the agency security owner. Use Maryland DoIT's [Cybersecurity & Privacy Policy Suite](https://doit.maryland.gov/policies/ci/Pages/default.aspx) and [transitional governing documents](https://doit.maryland.gov/policies/ci/cpp/Pages/Cybersecurity-and-Privacy-Policy-Transitional-Governing-Policy-Documents.aspx). The catalog keeps the older DoIT/NIST mappings so history stays traceable. Those mappings need review against current standards.

The requirements below retain the project's baseline. Confirm external deadlines, approval scope, and any stricter obligations before relying on them for a release. A checked-in policy is not authorization to operate.

## Application controls

| Area | Current implementation and boundary |
| --- | --- |
| Authentication | Passwords are hashed with BCrypt, a password-hashing algorithm. The minimum length is 12 characters (`UserAuthentication::PASSWORD_MIN_LENGTH`), and every new-password field states it. Accounts lock after repeated failures, and public sign-in, password reset, and account recovery are throttled. Multi-factor authentication (MFA) — a second proof such as a security key or a code, beyond the password — is required for administrators, evaluators, trainers, and vendors. Constituents can opt in. See [authentication](authentication_system.md). |
| Sessions | Session cookies are signed and carry the HttpOnly flag, plus Secure in production. HttpOnly hides the cookie from page scripts. Sessions expire after 24 hours by default. The previously stated 30-minute idle-timeout target is not implemented by that expiry. |
| Personal data | The application encrypts selected database fields before storing them (Active Record Encryption). Stable keys and safe logging are essential. See the [field inventory and key constraints](pii_encryption.md). |
| Requests and access | The base controller enables cross-site request forgery (CSRF) protection. Secure public forms and webhooks have explicit exemptions. CSRF is an attack that submits a forged request from another site while a user is signed in. Role checks, scoped record access, and purpose-specific token and throttle paths also apply. Public endpoints need their own authentication or token contract. |
| HTTPS and browser controls | Production forces HTTPS (`force_ssl`), which uses Transport Layer Security (TLS). Verify TLS versions and response headers at the deployment edge. The content-security policy (CSP) initializer is commented out, so it does not establish an active application policy. |
| Uploads | Proof uploads have content-type and size validation. The catalog does not establish malware-scanning coverage. |
| History and errors | Domain workflows write audit events. Production sends logs to standard output (stdout) and disables local exception detail pages. Log storage, retention, and alerting require deployment evidence. |

These descriptions identify code to inspect. They do not certify every entry point or environment.

## Operational requirements

The [reports and audits checklist](../compliance/required_reports_audits.md#schedule) owns review frequencies, responsible roles, and completion evidence. Keep scheduling changes there.

| Requirement | Evidence to maintain |
| --- | --- |
| Inventory software, infrastructure, providers, and data flows. Classify the data handled. | Current inventory and data-flow map, including a check against the State's prohibited technologies. |
| Store secrets in encrypted credentials or a managed key service. Keep plaintext secrets out of Git. | Access controls, key custody, and recovery procedure. Persistent data must never depend on temporary encryption keys. |
| Protect data in transit and at rest. | TLS 1.2+ configuration, storage and backup encryption settings, and reviewed field coverage. Rails `force_ssl` alone does not prove protocol or storage settings. |
| Rotate secrets and encryption keys using a tested migration and recovery procedure. | Rotation records and successful data and backup recovery. Automation and completion require operational evidence. |
| Generate a software bill of materials (SBOM) — a list of every component in the build — and scan dependencies in the continuous-integration (CI) pipeline. | Build artifacts and dependency-scan reports. These are requirements, not established current CI behavior. |
| Triage dependency alerts, apply security updates, and remediate vulnerabilities. | Dated scan and assessment reports, remediation owners, and deployment or retest evidence. Follow the checklist's deadlines and any stricter applicable requirements. |
| Centralize security logs for at least one year, with a 400-day project retention target. Alert on authentication spikes and privilege misuse. | Retention configuration, representative searches, and alert tests. |
| Review controls and exercise incident response and backup recovery. | Review record, tabletop results, and successful restore evidence. |

See [current automation](../compliance/required_reports_audits.md#current-automation) for the checks CI provides and the operational evidence still needed.

## Open policy checks

- Reconcile the MFA policy with applicable external-user requirements. The password minimum now matches the 12 characters in the cited [2021 external-user guidance](https://doit.maryland.gov/policies/ci/Pages/standards-and-guidance-for-authentication-of-external-users.aspx), which also sets sensitivity-based authentication requirements. Existing passwords shorter than 12 keep working until changed.
- Verify the stated BCrypt cost target of at least 12 (a work-factor setting for hashing), the session-idle timeout, and session replacement behavior before marking those controls complete.
- Confirm deployed TLS, headers and CSP, upload scanning, centralized logging, and retention. Source files alone do not establish hosting or provider controls.
- Replace unknown audit results with real reports and review dates. The catalog's null (empty) evidence fields mean unverified.

## Before production approval

The security owner should maintain the applicable approval package: system security plan, risk assessment and remediation plan, security assessment report, backup and contingency plan, incident response plan, change-control evidence, and Statement of Compliance.

Use [compliance reporting](../compliance/required_reports_audits.md) as a work list. Then confirm the required package and approval authority with the agency. Record actual approval and unresolved conditions before launch. Do not infer approval duration, hosting suitability, or compliance from this guide.

Update the catalog when an implementation changes. Follow the review schedule. Replace expired plans or placeholder evidence with current, attributable records.
