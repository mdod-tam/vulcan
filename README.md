# Vulcan: Maryland Accessible Telecommunications CRM

Vulcan is a Ruby on Rails application that powers the Maryland Accessible Telecommunications (MAT) program. The platform bridges the communication gap for Maryland residents who have difficulty using standard telephones by connecting them with accessible telecommunications equipment and program support services.

At its core, Vulcan manages a comprehensive application workflow to verify constituent eligibility. Approved applicants can move through voucher or equipment-fulfillment workflows, redeem vouchers through authorized vendors, and receive supplementary services such as training and evaluation.

To ensure participants maintain access to modern technology as their needs evolve, the MAT program operates on a three-year lifecycle. Once an application cycle concludes, constituents may reapply to qualify for a new voucher, equipment support, and further training services.

## Table of Contents

- [Features](#features)
- [Technical Stack](#technical-stack)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Database and Seeding](#database-and-seeding)
- [Running the App](#running-the-app)
- [Default Development Users](#default-development-users)
- [Testing](#testing)
- [Deployment](#deployment)
- [Maintenance Tasks](#maintenance-tasks)
- [Contributing](#contributing)

## Features

### Application Lifecycle

- Constituent portal applications with autosave, inline validation, proof upload, and status tracking.
- Admin paper-intake workflow guarded by `Current.paper_context`, with paper-specific validation and side-effect behavior.
- Application statuses for draft, in-progress, proof collection, disability certification, approval, rejection, and archival.
- Explicit status transition history through `ApplicationStatusChange` and `AuditEventService`.
- Eligibility rules for income proof, residency proof, ID proof, disability certification, and voucher/equipment fulfillment.
- Policy-driven three-year service window and training-session limits.

### Guardian and Dependent Management

- Many-to-many guardian/dependent relationships through `GuardianRelationship`.
- Managing guardian assignment for dependent applications.
- Communication routing to the managing guardian when a dependent should not receive direct messages.
- Authorization scopes for viewing, editing, and managing applications across constituent, guardian, and admin contexts.

### Proof Management

- Income, residency, and ID proof uploads with independent status tracking.
- `ProofAttachmentService` as the shared attachment entry point across portal, admin, paper, and secure-form submissions.
- Admin review through `ProofReview`, `Applications::ProofReviewer`, and proof-specific rejection reasons.
- Secure proof resubmission links for rejected or missing proof, including first rejection and re-rejection paths.
- Rate limits, validation, audit logging, and admin visibility for proof submission and review activity.

### Secure Public Forms

Secure public forms are tokenized, unauthenticated, time-boxed forms for a specific task. They are not portal sessions.

- Provider-info collection through `SecureRequestForm`.
- Proof resubmission through `SecureProofFormsController`.
- Disability certification upload through `MedicalProviderSecureRequestForm`.
- Vendor W9 resubmission through `VendorSecureRequestForm`.
- Token digests are stored instead of raw bearer tokens.
- Revoked, expired, submitted, and invalid links render neutral public responses.
- Expiration activity is recorded by `RecordSecureFormExpirationsJob`.

### Disability Certification

- Disability certification status tracking from request through receipt, approval, or rejection.
- DocuSeal digital signing through `DocumentSigning::SubmissionService` and the DocuSeal webhook.
- Secure certification upload links for provider corrections or fallback upload.
- Staff-managed fax, mail, and admin upload workflows.
- Additional certification artifacts can be retained for review when a later DocuSeal or upload result arrives after a primary artifact.

### Voucher and Equipment Fulfillment

- Snapshot fields on applications for fulfillment type and income-proof requirement.
- Voucher issuance for eligible voucher-fulfillment applications.
- Policy-driven voucher values by disability type and voucher validity period.
- Voucher status tracking for issued, active, redeemed, expired, and cancelled vouchers.
- Vendor redemption workflow with transaction records and audit history.
- Equipment-fulfillment paths with evaluation/training support where applicable.

### Vendor Portal, W9 Review, and Invoicing

- Vendor portal for voucher verification, redemption, transaction history, and authenticated W9 uploads.
- Admin W9 review and rejection workflow.
- Secure W9 resubmission links for rejected W9s.
- Vendor invoices generated from completed voucher transactions.
- Vendor-facing notifications for W9, invoice, payment, and voucher events.

### Training and Evaluation

- Trainer assignment, scheduling, completion, cancellation, and follow-up handling.
- Trainer dashboard and trainer session history.
- Evaluator assignment, scheduling, rescheduling, completion, and report submission.
- Evaluator dashboard with status filters.
- Activity history on training and evaluation records, including schedule and completion events.
- Training request queues driven by `applications.training_requested_at`.

### Administration

- Admin application dashboard with filters, search, proof queues, provider-info queues, training queues, and status views.
- Application detail pages for proof review, disability certification, secure request forms, training/evaluation status, vouchers, notes, and audit history.
- User management for constituents, guardians, administrators, trainers, evaluators, and vendors.
- Vendor management, W9 review, invoice review, and voucher administration.
- Policy and feature-flag management.
- Print queue support for paper correspondence.
- Draft pain-point analysis for application drop-off review.

### Notifications, Audit, and Activity History

- Database-backed email templates with English and Spanish seed data.
- Email delivery through Postmark.
- SMS and fax integrations through Twilio where configured.
- Paper letters through `PrintQueueItem`.
- `NotificationService` for delivery records and notification workflows.
- `AuditEventService` for domain audit events.
- `Applications::EventDeduplicationService` for readable application timelines.
- Application, proof, certification, secure-form, voucher, training, evaluation, vendor, and W9 history views.

### Security and Authentication

- Session-based authentication with secure password handling.
- Two-factor authentication by WebAuthn, TOTP, and SMS.
- Account recovery workflow with admin review.
- PII filtering and Active Record encryption for sensitive fields.
- Request-scoped public secure forms that do not create user sessions or expose unrelated account data.
- Voucher redemption controls and audit trails.

### Background Jobs and Recurring Work

- Solid Queue-backed jobs for email status updates, voucher expiration, vendor invoices, proof metrics, admin notifications, and secure form expiration events.
- Solid Cache and Solid Cable are configured through Rails 8 database-backed infrastructure.

## Technical Stack

- Ruby 4.0.2
- Rails 8.1.3
- PostgreSQL 17+
- Tailwind CSS
- Propshaft
- Stimulus and Turbo
- Solid Queue, Solid Cache, and Solid Cable
- Postmark for outbound email
- Twilio for SMS and fax status integrations
- DocuSeal for document signing
- Active Storage with local disk in development/test and S3-compatible storage in production
- Minitest with FactoryBot

## Architecture

- Service-oriented business logic with `BaseService` and structured result objects.
- STI user model for authenticating roles: `Users::Constituent`, `Users::Administrator`, `Users::Vendor`, `Users::Evaluator`, and `Users::Trainer`.
- Request-scoped state through `Current.user` and `Current.paper_context`.
- Explicit lifecycle transitions through `Application#transition_status!` and workflow reconciliation helpers.
- Separate delivery records, audit records, and status-change records.
- Secure public request models for unauthenticated, bounded collection tasks.
- Stimulus controllers and Turbo for progressive frontend behavior.
- Minitest test coverage for models, services, controllers, jobs, mailers, and system flows.

## Documentation

The links below point to tracked repository documentation intended to be available on GitHub.

### Current Feature Map

- [Current Application Features](docs/current_application_features.md)

### Development Guides

- [Testing and Debugging Guide](docs/development/testing_and_debugging_guide.md)
- [Service Architecture](docs/development/service_architecture.md)
- [JavaScript Architecture](docs/development/javascript_architecture.md)
- [Guardian Relationship System](docs/development/guardian_relationship_system.md)
- [Paper Application Architecture](docs/development/paper_application_architecture.md)
- [User Management Features](docs/development/user_management_features.md)
- [DocuSeal Integration Guide](docs/development/docuseal_integration_guide.md)

### Feature Documentation

- [Application Workflow Guide](docs/features/application_workflow_guide.md)
- [Proof Review Process Guide](docs/features/proof_review_process_guide.md)
- [Notification System](docs/features/notifications.md)
- [Audit and Event Tracking](docs/features/audit_event_tracking.md)
- [Pain Point Tracking](docs/features/application_pain_point_tracking.md)

### Infrastructure, Security, and Compliance

- [Active Storage S3 Setup](docs/infrastructure/active_storage_s3_setup.md)
- [Authentication System](docs/security/authentication_system.md)
- [PII Encryption](docs/security/pii_encryption.md)
- [Voucher Security Controls](docs/security/voucher_security_controls.md)
- [Required Reports and Audits](docs/compliance/required_reports_audits.md)

## Prerequisites

- Ruby 4.0.2
- Bundler
- PostgreSQL 17 or newer
- Node.js 24.x
- Yarn
- A Rails master key for shared credentials, or permission to generate local credentials for development

## Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/mdod-tam/vulcan.git
   cd vulcan
   ```

2. Install Ruby dependencies:

   ```bash
   bundle install
   ```

3. Install JavaScript dependencies:

   ```bash
   yarn install
   ```

4. Prepare credentials:

   If you have the team master key, place it in `config/master.key`.

   For an isolated local setup, generate local credentials:

   ```bash
   EDITOR="vim" bin/rails credentials:edit
   bin/rails db:encryption:init
   EDITOR="vim" bin/rails credentials:edit
   ```

   Add the generated Active Record encryption keys under `active_record_encryption`. Do not commit `config/master.key`.

## Configuration

### Required Local Configuration

The default development database expects PostgreSQL on localhost with username `postgres`. Override with environment variables when needed:

```bash
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=your_password
```

Development and test use local Active Storage by default.

### Production Environment Variables

Set these in production:

```bash
RAILS_MASTER_KEY=...
DATABASE_URL=postgres://...
APPLICATION_HOST=your-host.example
```

Optional production database URLs:

```bash
QUEUE_DATABASE_URL=postgres://...
CACHE_DATABASE_URL=postgres://...
CABLE_DATABASE_URL=postgres://...
```

Optional runtime settings:

```bash
RAILS_MAX_THREADS=10
SOLID_QUEUE_POOL_SIZE=10
WEB_CONCURRENCY=2
SOLID_QUEUE_IN_PUMA=true
WEBAUTHN_RP_ID=your-host.example
WEBAUTHN_ORIGIN=https://your-host.example
```

### Production Credentials and Integrations

Configure these through Rails credentials or environment variables, depending on the integration:

- Postmark API token for outbound email.
- DocuSeal API key and optional base URL.
- Twilio account settings for SMS and fax status integrations.
- Webhook secret for signed webhooks.
- S3-compatible storage:

  ```bash
  S3_ACCESS_KEY_ID=...
  S3_SECRET_ACCESS_KEY=...
  S3_REGION=us-east-1
  S3_BUCKET=...
  ```

  Bucketeer-compatible alternatives are also supported:

  ```bash
  BUCKETEER_AWS_ACCESS_KEY_ID=...
  BUCKETEER_AWS_SECRET_ACCESS_KEY=...
  BUCKETEER_AWS_REGION=...
  BUCKETEER_BUCKET_NAME=...
  ```

## Database and Seeding

### Development Database

Create, migrate, and seed a local development database:

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed
```

`db:seed` is a development seed. It creates demo users, products, policies, feature flags, fixtures, email templates, rejection reasons, and sample attachments. It uses FactoryBot and clears existing local data.

To refresh email templates only:

```bash
bin/rails db:seed_manual_email_templates
```

To seed policy rows only:

```bash
bin/rails db:seed_policies
```

### Production Seeding

Do not run `bin/rails db:seed` in production. It is development-oriented and clears data.

For production, run only targeted seeds:

```bash
bin/rails db:seed_policies
bin/rails db:seed_manual_email_templates
```

Create the first admin user through the Rails console:

```ruby
Users::Administrator.create!(
  email: 'admin@example.org',
  password: 'replace-with-a-secure-password',
  first_name: 'Admin',
  last_name: 'User',
  email_verified: true
)
```

## Running the App

Start the full development stack:

```bash
./bin/dev
```

This starts the Rails web process, JavaScript build watcher, Tailwind build watcher, and Solid Queue worker through `Procfile.dev`.

To run Rails only:

```bash
bin/rails server
```

The default local URL is:

```text
http://localhost:3000
```

## Default Development Users

After `bin/rails db:seed`, these development users are available:

| Role | Email | Password |
|---|---|---|
| Admin | `admin@example.com` | `password123` |
| Constituent | `user@example.com` | `password123` |
| Constituent | `user2@example.com` | `password123` |
| Trainer | `trainer@example.com` | `password123` |
| Evaluator | `evaluator@example.com` | `password123` |
| Vendor | `ray@testemail.com` | `password123` |
| Vendor | `teltex@testemail.com` | `password123` |
| Legacy medical-provider fixture | `medical@example.com` | `password123` |

Providers do not need portal accounts for the current secure certification upload workflow; the medical-provider seed is retained as fixture data.

## Testing

Run the full test suite:

```bash
bin/rails test
```

Run system tests:

```bash
bin/rails test:system
```

Run all configured tests:

```bash
bin/rails test:all
```

Run a focused test file:

```bash
bin/rails test test/models/application_test.rb
```

Run a focused test line:

```bash
bin/rails test test/models/application_test.rb:42
```

Run RuboCop on touched Ruby files:

```bash
bin/rubocop app/models/application.rb
```

Run pre-deploy checks:

```bash
ruby bin/pre-deploy-checks
```

## Deployment

### Heroku-Style Deployment

1. Set required configuration:

   ```bash
   heroku config:set RAILS_MASTER_KEY=... --app your-app-name
   heroku config:set APPLICATION_HOST=your-app-name.herokuapp.com --app your-app-name
   ```

2. Configure production database, Postmark, S3-compatible storage, DocuSeal, Twilio, and webhook secrets.

3. Deploy and migrate:

   ```bash
   git push heroku main
   heroku run bin/rails db:migrate --app your-app-name
   ```

4. Seed production-safe records:

   ```bash
   heroku run bin/rails db:seed_policies --app your-app-name
   heroku run bin/rails db:seed_manual_email_templates --app your-app-name
   ```

5. Create an admin user through `heroku run bin/rails console`.

6. Ensure a worker process is running for Solid Queue, or set `SOLID_QUEUE_IN_PUMA=true` when intentionally running jobs in Puma.

### Kamal Deployment

The repository includes `config/deploy.yml` for Kamal-based deployment. Update these before use:

- `service`
- `image`
- `servers`
- `proxy.host`
- registry credentials
- production secrets, especially `RAILS_MASTER_KEY`
- database, storage, and integration settings

Then deploy with:

```bash
bin/kamal deploy
```

Use the configured aliases for console, logs, shell, and database console:

```bash
bin/kamal console
bin/kamal logs
bin/kamal shell
bin/kamal dbc
```

## Maintenance Tasks

Useful targeted tasks:

```bash
bin/rails db:seed_policies
bin/rails db:seed_manual_email_templates
bin/rails data_integrity:find_orphaned_applications
bin/rails notification_tracking:check_all
bin/rails notification_tracking:analyze[123]
bin/rails letters:check_consistency
```

Recurring work is configured in `config/recurring.yml` and processed by Solid Queue.

## Contributing

1. Create a feature branch.
2. Make the smallest coherent change.
3. Run focused tests for the changed behavior.
4. Run RuboCop on touched Ruby files.
5. Update documentation when behavior or setup changes.
6. Open a pull request with the behavior change, verification performed, and any remaining risks.

## Acknowledgments

- Maryland Accessible Telecommunications Program
- Contributors and maintainers
