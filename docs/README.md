# MAT "Vulcan" Documentation

These guides explain the main workflows, the constraints that matter, and where to find their code and tests.

For installation and a repository map, start with the [project README](../README.md).

Setup shortcuts: [baseline seeds](infrastructure/setup_and_maintenance.md#baseline-seeds), [initial accounts](infrastructure/setup_and_maintenance.md#initial-accounts), and [Heroku deployment and operations](infrastructure/setup_and_maintenance.md#heroku-deployment-and-operations).

## First read

1. [Current features](current_application_features.md) explains what the application does.
2. [Application workflow](features/application_workflow_guide.md) follows a request from draft through review and fulfillment.
3. [Service architecture](development/service_architecture.md) identifies the code that owns those operations.

A few terms help when reading the code: a **constituent** receives assistance; an **application** is one request for assistance; a **managing guardian** acts for a dependent on that application; and **DCF** means disability certification form. Proof decisions, certification status, and overall application status are tracked separately.

## Find the guide for your change

| Area being reviewed | Read together |
| --- | --- |
| Intake or application status | [Application workflow](features/application_workflow_guide.md), [paper intake](development/paper_application_architecture.md), and [service architecture](development/service_architecture.md). |
| Account matching, guardians, or recipients | [User management](development/user_management_features.md), [guardian relationships](development/guardian_relationship_system.md), [authentication](security/authentication_system.md), and [notifications](features/notifications.md). |
| Uploads or provider responses | [Proof review](features/proof_review_process_guide.md) and [DocuSeal integration](development/docuseal_integration_guide.md). |
| Forms or browser behavior | [JavaScript architecture](development/javascript_architecture.md) and [testing/debugging](development/testing_and_debugging_guide.md). |
| Messages or delivery history | [Notifications](features/notifications.md), [email/letters](infrastructure/email_system.md), and [audit tracking](features/audit_event_tracking.md). |

Use the source and test links in the workflow guides to trace the current path. The [security baseline](security/baseline_policy.md) distinguishes policy requirements from implemented controls; the [control catalog](security/controls.yaml) records evidence still needed.

## Development

| Guide | Use it for |
| --- | --- |
| [Testing and debugging](development/testing_and_debugging_guide.md) | Running focused tests, setting up data, and diagnosing failures. |
| [Service architecture](development/service_architecture.md) | Workflow owners, result contracts, transactions, and shared locks. |
| [JavaScript architecture](development/javascript_architecture.md) | Stimulus, Turbo, form state, requests, and password visibility. |
| [User management](development/user_management_features.md) | Accounts, duplicate review, merging, and admin actions. |
| [Guardian relationships](development/guardian_relationship_system.md) | Relationships, dependent contact choices, delivery ownership, and access. |
| [Paper application intake](development/paper_application_architecture.md) | Staff intake, identity review, save outcomes, and retry restoration. |
| [DocuSeal integration](development/docuseal_integration_guide.md) | Disability-certification signing, webhooks, and configuration. |

## Workflows

| Guide | Use it for |
| --- | --- |
| [Application workflow](features/application_workflow_guide.md) | Drafts, autosave reporting, submission, approval, and fulfillment. |
| [Proof review](features/proof_review_process_guide.md) | Document intake, review, secure resubmission, and certification. |
| [Notifications](features/notifications.md) | Delivery ownership, recipients, intentional non-delivery, and troubleshooting. |
| [Audit and event tracking](features/audit_event_tracking.md) | Event creation, deduplication, actors, and displayed history. |

## Operations, security, and compliance

| Guide | Use it for |
| --- | --- |
| [Email and letters](infrastructure/email_system.md) | Templates, Postmark, printable letters, and delivery tracking. |
| [Active Storage and S3](infrastructure/active_storage_s3_setup.md) | File-storage configuration and deployment options. |
| [Backup and recovery](infrastructure/backup_and_recovery.md) | Required keys/files, settings that must match, and Heroku backup schedules and restores. |
| [Authentication and MFA](security/authentication_system.md) | Sign-in, sessions, factors, password reset, and recovery. |
| [PII encryption](security/pii_encryption.md) | Encrypted fields, contact lookup, stable keys, and logging. |
| [Voucher controls](security/voucher_security_controls.md) | Issuance, vendor verification, redemption, and history. |
| [Security baseline](security/baseline_policy.md) | Policy requirements, implementation boundaries, and approval needs. |
| [Control catalog](security/controls.yaml) | Control IDs, source pointers, and verification still needed. |
| [Reports and audits](compliance/required_reports_audits.md) | Operational review schedules, responsible roles, and evidence. |

## Planned work

[MAT Vulcan TODOs](future_work/mat_vulcan_todos.md) records proposed work. Use the guides above for current behavior.
