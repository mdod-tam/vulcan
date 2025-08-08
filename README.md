# Vulcan: Maryland Accessible Telecommunications CRM

Vulcan is a Ruby on Rails application that facilitates Maryland Accessible Telecommunications (MAT) workflows.

## Features

1. **Applications (Portal + Paper)**
   - Portal flow with autosave and inline validation
   - Admin-only paper path guarded by `Current.paper_context`; approvals require attachments, rejections may proceed without a file
   - Status tracking with comprehensive audit trails
   - Guardian/dependent application support

2. **Guardian & Dependent Management**
   - Explicit `GuardianRelationship` records (many-to-many)
   - Contact strategies for dependents (own vs guardian email/phone)
   - Notifications for dependent apps route to the managing guardian

3. **Proofs**
   - Unified `ProofAttachmentService` for web, paper, and email (fax supported for outbound only)
   - Resubmission and rate-limit policies; robust error handling
   - Centralized approval/rejection via reviews with audit logging

4. **Medical Certification**
   - Request and track provider responses
   - Channels: Email (automated via Action Mailbox), Fax (outbound only; inbound handled manually), Mail (admin scan/upload)
   - Integrated with audit events and notifications

5. **Notifications**
   - Email via `NotificationService` + database-backed templates
   - In-app uses Rails flash (no JS toast layer). Email is the only implemented channel today

6. **Audit & Events**
   - Central `AuditEventService` + `Applications::EventDeduplicationService`
   - Deduplicated audit & event history used across admin timelines and dashboards

7. **Vouchers & Vendors**
   - Voucher issuance and redemption with security controls
   - Vendor workflows including W9 review and invoicing

8. **Admin & Reporting**
   - Dashboards, filters, timelines, and pain-point analysis for draft drop-off

9. **Security & Authentication**
   - 2FA: WebAuthn, TOTP, and SMS; standardized flows and auditing

## Current Implementation Status

- ✅ 2FA (WebAuthn, TOTP, SMS) and standardized auth flows
- ✅ Guardian/dependent relationships with contact strategies
- ✅ Paper application path with `Current.paper_context`
- ✅ Unified proof attachment + review with audits
- ✅ Medical certification: email automation; fax outbound only
- ✅ Action Mailbox for inbound emails
- ✅ Voucher management and vendor workflows (incl. W9)
- ✅ Admin dashboards, filters, and draft pain-point analysis
- ✅ Comprehensive audit logging with event deduplication
- ⏳ Inbound fax automation
- ⏳ Enhanced reporting and duplicate-review admin UI

## Technical Stack

- **Ruby** 3.4.5
- **Rails** 8.0.2
- **PostgreSQL**
- **Tailwind CSS**
- **Propshaft Asset Pipeline**
- **Solid Queue** (for background jobs)
- **Postmark** (for email delivery)
- **Action Mailbox** (for inbound email processing)
- **AWS S3** (for file storage)
- **Twilio** (for SMS and fax services)

## Architecture

- **Service-Oriented**: Business logic lives in service objects (e.g., `ProofAttachmentService`, `Applications::PaperApplicationService`).
- **Stimulus + JS Services**: Centralized `rails_request`, chart config, and target-safety mixin; Rails flash for in-app messages.
- **CurrentAttributes**: Request context (e.g., `paper_context`) without polluting models/controllers.
- **Audit Dedup**: `Applications::EventDeduplicationService` powers clean timelines.
- **Testing**: Minitest with helpers for auth, Current, and attachments.

## Documentation

- [Application Workflow Guide](docs/features/application_workflow_guide.md) - High-level overview of all major application flows.
- [Proof Review Process Guide](docs/features/proof_review_process_guide.md) - Detailed guide to the proof submission, review, and approval lifecycle.
- [Guardian Relationship System](docs/development/guardian_relationship_system.md) - How guardian and dependent relationships are modeled and managed.
- [Paper Application Architecture](docs/development/paper_application_architecture.md) - Deep dive into the admin-facing paper application workflow.
- [Notification System](docs/features/notifications.md) - Email notifications and Rails flash patterns.
- [Audit & Event Tracking](docs/features/audit_event_tracking.md) - Central logging and deduplication.
- [JavaScript Architecture](docs/development/javascript_architecture.md) - Stimulus patterns and core services.
- [Pain Point Tracking](docs/features/application_pain_point_tracking.md) - Draft drop-off analysis.
- [Email System Guide](docs/infrastructure/email_system.md) - Inbound and outbound email, templates.
- [Voucher Security Controls](docs/security/voucher_security_controls.md) - Security measures for the voucher system.
- [Testing and Debugging Guide](docs/development/testing_and_debugging_guide.md) - Comprehensive guide for running and debugging the test suite.

## Prerequisites

- Ruby 3.4.5 or higher
- PostgreSQL 17 or higher
- Node.js v22 (LTS) or higher
- Yarn

## Setup

1. **Clone the repository**:
   ```bash
   git clone https://github.com/yourusername/vulcan.git
   cd vulcan
   ```

2. Install dependencies:
   ```bash
   bundle install
   yarn install
   ```

3. Setup database:
   ```bash
   bin/rails db:create
   bin/rails db:migrate
   bin/rails db:seed
   ```

3a. Seed email templates:
   ```bash
   bin/rails db:seed:email_templates
   ```
   This command populates the `email_templates` table with the default email and letter templates used by the application.

4. Set up environment variables:
   ```bash
   cp config/application.yml.example config/application.yml
   # Edit application.yml with your credentials
   ```

5. Start the server:
   ```bash
   ./bin/dev # For development with hot-reloading
   bin/rails server
   ```

## Testing

The application uses Minitest for testing. To run the test suite:

```bash
bin/rails test
bin/rails test:system # For system tests
```

FactoryBot is used for test data generation. Factories can be found in `test/factories/`.

## Default Users

After seeding, the following test users are available:

| Role | Email | Password |
|------|-------|----------|
| Admin | admin@example.com | password123 |
| Evaluator | evaluator@example.com | password123 |
| Constituent | user@example.com | password123 |
| Vendor | ray@testemail.com | password123 |
| Medical Provider | medical@example.com | password123 |

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

## Acknowledgments

- Maryland Accessible Telecommunications Program
- Contributors and maintainers
