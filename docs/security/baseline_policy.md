# Security Baseline

This policy covers MAT Vulcan's code, infrastructure, environments, and providers that handle agency data.

It states the security requirements and the evidence needed to assess them.

[controls.yaml](controls.yaml) maps stable control IDs to implementation descriptions and source files. [Security hardening tasks](../future_work/mat_vulcan_todos.md#security-hardening) live in the project TODOs.

## Policy authority

Confirm the applicable requirements with the agency security owner. Use Maryland DoIT's [Cybersecurity & Privacy Policy Suite](https://doit.maryland.gov/policies/ci/Pages/default.aspx) and [transitional governing documents](https://doit.maryland.gov/policies/ci/cpp/Pages/Cybersecurity-and-Privacy-Policy-Transitional-Governing-Policy-Documents.aspx).

The security owner records the applicable deadlines and approval scope before production use.

## Application controls

| Area | Current implementation and boundary |
| --- | --- |
| Authentication | Passwords are hashed with BCrypt, a password-hashing algorithm. The minimum length is 12 characters (`UserAuthentication::PASSWORD_MIN_LENGTH`), and every new-password field states it. Accounts lock after repeated failures, and public sign-in, password reset, and account recovery are throttled. Multi-factor authentication (MFA) — a second proof such as a security key or a code, beyond the password — is required for administrators, evaluators, trainers, and vendors. Constituents can opt in. See [authentication](authentication_system.md). |
| Sessions | Session cookies are signed and carry the HttpOnly flag, plus Secure in production. HttpOnly hides the cookie from page scripts. Sessions expire after 24 hours by default. |
| Personal data | The application encrypts selected database fields before storing them (Active Record Encryption). Stable keys and safe logging are essential. See the [field inventory and key constraints](pii_encryption.md). |
| Requests and access | The base controller enables cross-site request forgery (CSRF) protection. Secure public forms and webhooks have explicit exemptions. CSRF is an attack that submits a forged request from another site while a user is signed in. Role checks, scoped record access, and purpose-specific token and throttle paths also apply. Public endpoints need their own authentication or token contract. |
| HTTPS | Production forces HTTPS (`force_ssl`), which uses Transport Layer Security (TLS). |
| Uploads | Proof uploads have content-type and size validation. |
| History and errors | Domain workflows write audit events. Production sends logs to standard output (stdout) and disables local exception detail pages. |

## Operational requirements

The [reports and audits checklist](../compliance/required_reports_audits.md#schedule) owns review frequencies, responsible roles, and completion evidence. Keep scheduling changes there.

| Requirement | Evidence to maintain |
| --- | --- |
| Inventory software, infrastructure, providers, and data flows. Classify the data handled. | Current inventory and data-flow map, including a check against the State's prohibited technologies. |
| Store secrets in encrypted credentials or a managed key service. Keep plaintext secrets out of Git. | Access controls, key custody, and recovery procedure. Persistent data must never depend on temporary encryption keys. |
| Protect data in transit and at rest. | TLS 1.2+ configuration, storage and backup encryption settings, and reviewed field coverage. |
| Rotate secrets and encryption keys using a tested migration and recovery procedure. | Rotation records and successful data and backup recovery. |
| Generate a software bill of materials (SBOM) — a list of every component in the build — and scan dependencies in the continuous-integration (CI) pipeline. | Build artifacts and dependency-scan reports. |
| Triage dependency alerts, apply security updates, and remediate vulnerabilities. | Dated scan and assessment reports, remediation owners, and deployment or retest evidence. Follow the checklist's deadlines and any stricter applicable requirements. |
| Centralize security logs for at least one year, with a 400-day project retention target. Alert on authentication spikes and privilege misuse. | Retention configuration, representative searches, and alert tests. |
| Review controls and exercise incident response and backup recovery. | Review record, tabletop results, and successful restore evidence. |

See [current automation](../compliance/required_reports_audits.md#current-automation) for the configured CI checks.

## Before production approval

The security owner should maintain the applicable approval package: system security plan, risk assessment and remediation plan, security assessment report, backup and contingency plan, incident response plan, change-control evidence, and Statement of Compliance.

Use [compliance reporting](../compliance/required_reports_audits.md) as a work list. Then confirm the required package and approval authority with the agency. Record approval and its conditions before launch.

Update the catalog when an implementation changes. Maintain assessment records on the review schedule.
