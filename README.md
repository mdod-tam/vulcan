# Vulcan: Maryland Accessible Telecommunications CRM

Vulcan is a Ruby on Rails application that facilitates Maryland Accessible Telecommunications (MAT) workflows. It manages the complete lifecycle of assistive technology voucher applications for constituents with difficulties using a standard telephone, from initial application through training and equipment distribution.

## Features

### Core Application Management

1. **Applications (Portal + Paper)**
   - Self-service portal flow with autosave and inline validation
   - Admin-only paper path guarded by `Current.paper_context`; approvals require attachments, rejections may proceed without a file
   - Status tracking: draft → in_progress → approved/rejected/needs_information
   - Guardian/dependent application support with managing guardian tracking

2. **Guardian & Dependent Management**
   - Explicit `GuardianRelationship` records (many-to-many)
   - Managing guardian assignment for dependent applications
   - Notifications for dependent apps route to the managing guardian
   - Authorization scopes for viewing/editing applications

3. **Proof Management**
   - Income and residency proof uploads with status tracking
   - Unified `ProofAttachmentService` for web, paper, and email submissions
   - Resubmission and rate-limit policies; robust error handling
   - Centralized approval/rejection via `ProofReviewService` with audit logging

4. **Medical Certification**
   - Request and track provider responses
   - Channels: 
     - **Email**: Automated via Action Mailbox (`MedicalCertificationMailbox`)
     - **Fax**: Outbound automated, inbound handled manually
     - **Mail**: Admin scan/upload
     - **DocuSeal**: Digital document signing (production-ready)
   - Dual status tracking for e-signature workflow + admin approval
   - Integrated with audit events and notifications

### Voucher System

5. **Vouchers**
   - Auto-assignment when application approved + all proofs verified
   - Value calculation based on constituent disability types
   - Configurable expiration via Policy settings
   - Security controls including redemption verification

6. **Vendor Portal**
   - Voucher verification and redemption workflow
   - Transaction history and reporting
   - W9 review and approval process
   - Invoice generation and management

### Training & Evaluation

7. **Training Sessions**
   - Trainer assignment and scheduling
   - Session status tracking (requested → scheduled → completed)
   - Dedicated trainer portal with dashboard

8. **Evaluations**
   - Evaluator assignment workflow
   - Evaluation scheduling and completion
   - Dedicated evaluator portal with filtering and status views

### Administration

9. **Admin Dashboard**
   - Application pipeline visualization
   - Filters, search, and bulk operations
   - Pain-point analysis for draft drop-off
   - Print queue management for letters

10. **Notifications**
    - Email via `NotificationService` + database-backed templates with versioning
    - Paper letters for snail mail via `PrintQueueItem`
    - Rails native flash for in-app messages
    - Postmark integration with delivery tracking and webhooks

11. **Audit & Events**
    - Central `AuditEventService` for consistent logging
    - `Applications::EventDeduplicationService` for clean timelines
    - `ApplicationStatusChange` records for status history

### Security & Authentication

12. **Authentication**
    - Session-based authentication with secure password handling
    - Two-factor authentication: WebAuthn, TOTP (authenticator apps), SMS
    - Account recovery workflow with admin approval
    - Standardized auth flows and auditing

## Current Implementation Status

### ✅ Complete

- 2FA (WebAuthn, TOTP, SMS) and standardized auth flows
- Guardian/dependent relationships with managing guardian assignment
- Paper application path with `Current.paper_context`
- Unified proof attachment + review with audits
- Medical certification: email automation; fax outbound only
- DocuSeal integration for digital document signing
- Action Mailbox for inbound emails
- Voucher management with auto-assignment logic
- Vendor portal with W9 review and invoicing
- Trainer and evaluator portals
- Admin dashboards, filters, and draft pain-point analysis
- Comprehensive audit logging with event deduplication
- Print queue for paper correspondence

### ⏳ In Progress / Planned

- Inbound fax automation (Twilio webhook processing)
- Live chat functionality with transcript capture
- Tooltips and inline help system
- Duplicate detection with merge/ignore workflows
- Custom report builder with CSV export
- Notification analytics dashboard
- Enhanced audit event browsing and export
- Dependent contact strategies (email/phone source selection)

## Technical Stack

- **Ruby** 3.4.7
- **Rails** 8.0.3
- **PostgreSQL** 17+
- **Tailwind CSS**
- **Propshaft** (Asset Pipeline)
- **Solid Queue** (Background Jobs)
- **Solid Cache** (Caching)
- **Solid Cable** (WebSocket)
- **Postmark** (Email Delivery)
- **Action Mailbox** (Inbound Email)
- **AWS S3** (File Storage)
- **Twilio** (SMS and Fax)
- **DocuSeal** (Document Signing)
- **Stimulus + Turbo** (Frontend Interactivity)

## Architecture

- **Service-Oriented**: Business logic encapsulated in service objects (e.g., `ProofAttachmentService`, `Applications::PaperApplicationService`, `NotificationService`). Services inherit from `BaseService` and return structured `Result` objects.
- **STI User Model**: All user types inherit from `User` with fully namespaced classes (`Users::Constituent`, `Users::Administrator`, `Users::Vendor`, `Users::Evaluator`, `Users::Trainer`, `Users::MedicalProvider`).
- **CurrentAttributes**: Request-scoped state management (e.g., `Current.paper_context`, `Current.user`) without polluting models/controllers.
- **Stimulus + Turbo**: Frontend interactivity with Stimulus controllers and Turbo for SPA-like page updates. Centralized `rails_request` service for AJAX calls.
- **Audit System**: `AuditEventService` for consistent event logging, `Applications::EventDeduplicationService` for clean timelines, `ApplicationStatusChange` for status history.
- **Testing**: Minitest with FactoryBot, helpers for auth, Current attributes, and file attachments.

## Documentation

### Development Guides
- [Testing and Debugging Guide](docs/development/testing_and_debugging_guide.md) - Comprehensive guide for running and debugging the test suite
- [Service Architecture](docs/development/service_architecture.md) - Service objects, patterns, and best practices
- [JavaScript Architecture](docs/development/javascript_architecture.md) - Stimulus patterns and core services
- [Guardian Relationship System](docs/development/guardian_relationship_system.md) - Guardian/dependent modeling and management
- [Paper Application Architecture](docs/development/paper_application_architecture.md) - Admin-facing paper application workflow
- [User Management Features](docs/development/user_management_features.md) - User CRUD, deduplication, and factory recipes
- [DocuSeal Integration Guide](docs/development/docuseal_integration_guide.md) - Digital document signing for medical certifications

### Feature Documentation
- [Application Workflow Guide](docs/features/application_workflow_guide.md) - High-level overview of all major application flows
- [Proof Review Process Guide](docs/features/proof_review_process_guide.md) - Proof submission, review, and approval lifecycle
- [Notification System](docs/features/notifications.md) - Email notifications and Rails flash patterns
- [Audit & Event Tracking](docs/features/audit_event_tracking.md) - Central logging and deduplication
- [Pain Point Tracking](docs/features/application_pain_point_tracking.md) - Draft drop-off analysis

### Infrastructure
- [Email System Guide](docs/infrastructure/email_system.md) - Inbound and outbound email, templates
- [Active Storage S3 Setup](docs/infrastructure/active_storage_s3_setup.md) - File storage configuration

### Security
- [Authentication System](docs/security/authentication_system.md) - 2FA implementation (WebAuthn, TOTP, SMS)
- [Voucher Security Controls](docs/security/voucher_security_controls.md) - Security measures for the voucher system

## Prerequisites

- Ruby 3.4.7 or higher
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

3. Set up encryption:

   If you have access to the team's master.key, copy the value into config/master.key.

   Otherwise, set up encryption keys:
      ```bash
      # Use your preferred editor (vim, nano, code, etc.)
      EDITOR="vim" rails credentials:edit # Creates master.key
      rails db:encryption:init # Copy credentials displayed
      EDITOR="vim" rails credentials:edit  # Add the generated keys to your credentials
      ```

   Note: Do not commit the changes to config/credentials.yml.enc unless the whole team is changing their master key.

   Note: You'll need to set the `APPLICATION_HOST` environment variable in production (e.g., `myapp.herokuapp.com`).

4. Setup database:
   ```bash
   bin/rails db:create
   bin/rails db:migrate
   bin/rails db:seed
   ```

4a. Seed email templates:
   ```bash
   rake db:seed_manual_email_templates
   ```
   This command populates the `email_templates` table with the default email and letter templates used by the application.


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
bin/rails test:all # For all tests
```

FactoryBot is used for test data generation. Factories can be found in `test/factories/`.

## Default Users

After seeding (`bin/rails db:seed`), the following test users are available:

| Role | Email | Password |
|------|-------|----------|
| Admin | admin@example.com | password123 |
| Evaluator | evaluator@example.com | password123 |
| Trainer | trainer@example.com | password123 |
| Constituent | user@example.com | password123 |
| Vendor | ray@testemail.com | password123 |
| Medical Provider | medical@example.com | password123 |

**Note**: Email templates must be seeded separately with `rake db:seed_manual_email_templates`.

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
