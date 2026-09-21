# "Vulcan": Maryland Accessible Telecommunications CRM

Vulcan is a Ruby on Rails application that helps the Maryland Accessible Telecommunications (MAT) program connect Maryland residents with the accessible telecommunications equipment they need. It gives residents a way to apply for assistance and staff one place to manage applications and ongoing support.

Residents can apply online, guardians can apply on behalf of dependents, and staff can enter applications received on paper. Staff use Vulcan to review eligibility documents and disability certification, arrange equipment or vouchers for approved applicants, and coordinate evaluations and training. It also keeps track of benefit limits and when participants can apply again.

“Vulcan” and “MAT Vulcan” are internal project names. Public pages and messages use **Maryland Accessible Telecommunications**. The existing TOTP issuer remains `MatVulcan`; it is intentionally excluded from cosmetic naming changes. See [the story behind the name](docs/future_work/mat_vulcan_todos.md#why-mat-vulcan).

## Start here to:

- **Understand the product:** [current features](docs/current_application_features.md) and [application workflow](docs/features/application_workflow_guide.md).
- **Review the code:** follow the [architecture map](#architecture), then the relevant guide in the [documentation hub](docs/README.md).
- **Run it locally:** [installation](#installation), [database setup](#database-and-seeding), and [development users](#default-development-users).
- **Check a change:** [testing](#testing) and the [testing and debugging guide](docs/development/testing_and_debugging_guide.md).
- **Operate a deployment:** [configuration](#configuration), [deployment](#deployment), and [maintenance tasks](#maintenance-tasks).

## Features

Vulcan supports portal and paper intake, guardian/dependent relationships, proof review and resubmission, disability certification with DocuSeal or staff uploads, voucher redemption, vendor W9 review and invoicing, and evaluation/training scheduling. Staff also manage policies, notifications, printable letters, and audit history.

Authentication is implemented in this application with sessions and MFA. Time-limited public links let recipients complete a specific document task without a portal account. Constituent-facing content supports English and Spanish; admin-only screens may be English-only. See the [feature overview](docs/current_application_features.md) for details and implementation boundaries.

## Architecture

The root URL (`/`) opens sign-in for visitors and the appropriate dashboard for signed-in users. There is no introductory homepage; program information belongs on the surrounding MAT website. [HomeController](app/controllers/home_controller.rb) handles this redirect, with password-change and MFA requirements checked first.

Vulcan uses Rails' MVC structure: controllers handle requests, Active Record models manage database records and validations, and ERB views render pages. Turbo and Stimulus add interactive behavior, while form objects and services coordinate application workflows.

Active Storage manages uploaded documents, Action Mailer handles email, and Active Job queues background work through Solid Queue, including email delivery and voucher issuance.

### Where to look

| Area | Starting point |
| --- | --- |
| URLs and portal boundaries | [Routes](config/routes.rb): `Admin::`, `ConstituentPortal::`, `VendorPortal::`, `Evaluators::`, `Trainers::`, and `Webhooks::`. |
| Portal application submission | [ApplicationsController](app/controllers/constituent_portal/applications_controller.rb) → [ApplicationCreator](app/services/applications/application_creator.rb). |
| Staff paper intake | [PaperApplicationsController](app/controllers/admin/paper_applications_controller.rb) → [PaperApplicationService](app/services/applications/paper_application_service.rb). |
| Application lifecycle | [Application](app/models/application.rb) and [ApplicationStatusManagement](app/models/concerns/application_status_management.rb). |
| Business operations and their contracts | [Services](app/services) and the [service architecture guide](docs/development/service_architecture.md). |
| Browser behavior and rendered pages | [Views](app/views), [Stimulus registration](app/javascript/controllers/index.js), and [JavaScript architecture](docs/development/javascript_architecture.md). |
| Messages, templates, and background work | [Mailers](app/mailers), [template seeds](db/seeds/email_templates), [jobs](app/jobs), and [recurring schedules](config/recurring.yml). |
| Database shape and changes | [Schema](db/schema.rb) and [migrations](db/migrate). |
| Tests and sample data | [Tests](test), [factories](test/factories), and the [fixture guide](test/fixtures/README.md). |

The workflow guides link to focused tests and explain the boundaries shared by portal and paper intake.

### Domain rules worth knowing

- **A user and an application are different records.** A user is a person/account; an application is one request for assistance. Roles share the `users` table through STI: `Users::Constituent`, `Users::Administrator`, `Users::Vendor`, `Users::Evaluator`, `Users::Trainer`, and `Users::MedicalProvider`.
- **Applicant, guardian, and message recipient can differ.** A guardian relationship is distinct from an application's managing guardian. Contact ownership and public-login eligibility have separate rules; see [guardian relationships](docs/development/guardian_relationship_system.md) and [authentication](docs/security/authentication_system.md).
- **Lifecycle changes have side effects.** Use `Application#transition_status!` and `Application#reconcile_workflow_state!` to preserve status history and associated work. Application status, individual proof decisions, and disability certification are separate states.
- **Fulfillment is saved on each application.** At creation, `vouchers_enabled` determines voucher versus equipment fulfillment and whether income proof is required. Changing the flag does not rewrite existing applications; see [fulfillment settings](docs/features/application_workflow_guide.md#fulfillment-settings).
- **History has several owners.** `Event`, `ApplicationStatusChange`, `ProofReview`, and `Notification` answer different questions. Use the [audit guide](docs/features/audit_event_tracking.md) and [notification guide](docs/features/notifications.md) when tracing an outcome.
- **Paper context changes validation behavior.** `Current.paper_context` is scoped by paper-intake entry points. See [paper intake](docs/development/paper_application_architecture.md) before reusing that context.

## Documentation

The [documentation hub](docs/README.md) is the guide index. It covers workflows, architecture, testing, integrations, security, and operational reviews. Planned work is labeled separately from descriptions of current behavior.

## Technical Stack

Ruby 4.0.2 and Rails 8.1.3; PostgreSQL; ERB, Turbo, Stimulus, Tailwind, esbuild, and Propshaft; Solid Queue, Solid Cache, and Solid Cable; Active Storage; Minitest/FactoryBot, Cuprite, and Jest.

External integrations are Postmark for email, Twilio for SMS/fax status handling, DocuSeal for signing, and S3-compatible storage in production. Development uses local file storage and Letter Opener for email.

## Prerequisites

- Ruby from [`.ruby-version`](.ruby-version) and Bundler.
- PostgreSQL running locally; CI uses PostgreSQL 17.
- Node.js 24.x and Yarn 4.12.0, pinned by [`.yarnrc.yml`](.yarnrc.yml) and `packageManager` in [package.json](package.json). The older `engines.yarn` entry still says 1.22.x.
- Chrome or Chromium when running browser tests.
- The team credentials key, or an isolated development/test credentials setup as described below.

## Installation

```bash
git clone https://github.com/mdod-tam/vulcan.git
cd vulcan
bundle install
yarn install
```

Use the checked-in Yarn release if your global launcher selects a different version: `node .yarn/releases/yarn-4.12.0.cjs install`.

`bin/setup` currently passes the unsupported Yarn 1 `--check-files` option and ignores its failure. Use the installation and database commands here until that script is updated.

### Credentials

For shared credentials, obtain the matching key from a maintainer and place it in `config/master.key` or export `RAILS_MASTER_KEY`. Generating a new key will not decrypt the existing `config/credentials.yml.enc`.

For an isolated local setup, create environment-specific credentials without replacing the shared encrypted file:

```bash
EDITOR="vim" bin/rails credentials:edit --environment development
EDITOR="vim" bin/rails credentials:edit --environment test
```

Use `bin/rails db:encryption:init` to generate the `active_record_encryption` entries, then add stable keys to each local credentials file before saving data. Keep local keys and credentials out of your change. Missing encryption configuration falls back to temporary keys, which cannot reliably read saved records after a restart. See [PII encryption](docs/security/pii_encryption.md).

### Local environment

[Database configuration](config/database.yml) defaults to PostgreSQL at `localhost:5432` with username `postgres`. Export overrides in the shell that starts Rails:

```bash
export DATABASE_USERNAME=postgres
export DATABASE_PASSWORD=your_password
```

`bin/dev` starts Foreman with `--env /dev/null`; it does not load a project `.env` file. Development has separate primary, queue, and cable databases. The database tasks below use those configured connections; your PostgreSQL user needs permission to create the local databases.

## Database and Seeding

On a fresh local database:

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed
```

**The demo seed clears existing records.** Use it only with disposable local data. [db/seeds.rb](db/seeds.rb) creates users through factories, loads selected YAML data, seeds policies/templates, and attaches sample files. The test helper also uses it to prepare test data; see the [fixture guide](test/fixtures/README.md).

### Targeted seeds

These tasks initialize the baseline records for a new environment. Run them after migrations, in the intended Rails environment; for a standalone production install, prefix each command with `RAILS_ENV=production`. The [Heroku sequence](#heroku-style-deployment) runs them against the selected app.

| Task | Effect |
| --- | --- |
| `bin/rails db:seed_policies` | Initializes program policy defaults: income thresholds, waiting periods, training limits, throttles, secure-link timing, and voucher settings. |
| `bin/rails db:seed_feature_flags` | Creates missing flags; `vouchers_enabled` defaults to disabled. |
| `bin/rails db:seed_manual_email_templates` | Loads the checked-in email and letter templates; deletes existing `EmailTemplate` rows first. |
| `bin/rails db:seed_rejection_reasons` | Adds missing proof/certification rejection reasons. |

Review [policy defaults](lib/tasks/seed_policies.rake) during initialization. If rows already exist, this task updates differing values; routine policy changes belong in the [policy-management workflow](docs/features/application_workflow_guide.md#program-policies). Rerunning the template seed replaces staff-edited copy. The general `db:seed` task is for development/test, depends on FactoryBot, and skips its main seed body in production.

Products come from [products.yml](test/fixtures/products.yml) in the demo seed. There is no standalone product seed task; production products can be entered through the admin product workflow.

### Initial accounts

In the target environment's Rails console (`RAILS_ENV=production bin/rails console`, or `heroku run bin/rails console --app your-app-name`), provision the system audit account and the first staff administrator:

```ruby
User.system_user
raise 'System audit account missing' unless PublicAuditActor.system_audit_actor

Users::Administrator.create!(
  email: 'admin@example.org',
  password: 'replace-with-a-secure-password',
  first_name: 'Admin',
  last_name: 'User',
  email_verified: true
)
```

`User.system_user` provisions `system@mdmat.org` for audit attribution. Public requests deliberately do not create it: without it, public audit events are skipped and registrations requiring duplicate review roll back. The staff administrator is a separate account and must [enroll in MFA](docs/security/authentication_system.md#second-factors) on first sign-in.

## Running the App

```bash
bin/dev
```

Open [localhost:3000](http://localhost:3000). [Procfile.dev](Procfile.dev) starts Rails, JavaScript and CSS watchers, and a Solid Queue worker. Development email opens through Letter Opener. DocuSeal signing and Twilio delivery need their own configuration when exercising those integrations.

`bin/rails server` starts only the web process. If you use it, build assets with `yarn build` and `yarn build:css`, and run `bin/rails solid_queue:start` separately for queued work. A successful page load does not mean background deliveries or recurring jobs are running.

## Default Development Users

After the demo seed, these accounts use `password123`:

| Role | Email |
| --- | --- |
| Administrator | `admin@example.com` |
| Constituents | `user@example.com`, `user2@example.com` |
| Trainer | `trainer@example.com` |
| Evaluator | `evaluator@example.com` |
| Vendors | `ray@testemail.com`, `teltex@testemail.com` |
| Legacy medical-provider seed | `medical@example.com` |

Providers use secure certification links in the current workflow; they do not need a portal account.

## Testing

Start with a focused test, then expand to the affected area:

```bash
bin/rails test test/models/user_contact_predicates_test.rb
yarn test test/javascript/controllers/upload_controller_test.js --runInBand
bin/rubocop --cache false app/models/user.rb
```

`bin/rails test` runs the non-system Ruby suite; `yarn test` runs Jest. For a browser change, build assets and run one relevant system test:

```bash
yarn build
yarn build:css
SYSTEM_TEST_WORKERS=1 bin/rails test test/system/registrations_test.rb
```

The [CI workflow](.github/workflows/ci.yml) runs Brakeman, RuboCop, and `bin/rails test:all`, including the full browser suite. Keep local browser runs focused and avoid concurrent suites sharing the test database. See [testing and debugging](docs/development/testing_and_debugging_guide.md) for authentication helpers, data setup, and failure diagnosis.

## Configuration

### Production essentials

Set `RAILS_MASTER_KEY`, `DATABASE_URL`, and `APPLICATION_HOST` (the public hostname used in generated links and WebAuthn). Use stable Active Record encryption keys in credentials. Production uses HTTPS and S3-backed uploads.

`QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`, and `CABLE_DATABASE_URL` can override the auxiliary database connections; each otherwise falls back to `DATABASE_URL`. See [database.yml](config/database.yml), [Puma configuration](config/puma.rb), and [queue configuration](config/queue.yml) for connection pools and worker sizing.

### Integrations

| Integration | Configuration owner |
| --- | --- |
| Postmark | `postmark_api_token` in Rails credentials; [email and letters guide](docs/infrastructure/email_system.md). |
| DocuSeal | `docuseal.api_key`, optional `docuseal.base_url`, and signing setup in the [DocuSeal guide](docs/development/docuseal_integration_guide.md). |
| Twilio | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SMS_FROM_NUMBER`, `TWILIO_VERIFY_SERVICE_SID`, and `TWILIO_FAX_FROM_NUMBER` as needed; [initializer](config/initializers/twilio.rb). |
| Webhooks | Rails credentials `webhook_secret` for the shared signature verifier; Twilio fax callbacks use Twilio's signature. See [webhook controllers](app/controllers/webhooks). |
| S3 uploads | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_BUCKET`, or their Bucketeer alternatives; [storage guide](docs/infrastructure/active_storage_s3_setup.md). |

## Deployment

### Heroku-style deployment

The checked-in [Procfile](Procfile) defines web, worker, and release processes. Start with a Heroku app and attached Postgres database; [Heroku's Rails guide](https://devcenter.heroku.com/articles/getting-started-with-rails8#create-a-heroku-app) covers provisioning. Set the [production configuration](#production-essentials), including storage and integration credentials, then deploy the intended checkout:

```bash
export MAT_APP=your-app-name
heroku git:remote --app "$MAT_APP"
heroku config:set RAILS_MASTER_KEY=... --app "$MAT_APP"
heroku config:set APPLICATION_HOST=your-public-host --app "$MAT_APP"
git push heroku HEAD:main
heroku releases --app "$MAT_APP"
```

The [release phase](https://devcenter.heroku.com/articles/release-phase) runs `bin/rails db:migrate`; check that it succeeded before initializing data. For the first deployment:

```bash
heroku run bin/rails db:seed_policies --app "$MAT_APP"
heroku run bin/rails db:seed_feature_flags --app "$MAT_APP"
heroku run bin/rails db:seed_manual_email_templates --app "$MAT_APP"
heroku run bin/rails db:seed_rejection_reasons --app "$MAT_APP"
heroku run bin/rails console --app "$MAT_APP"
```

Use that console for [initial accounts](#initial-accounts). Then check the baseline data and start the web and worker processes:

```bash
heroku run bin/rails email_templates:audit --app "$MAT_APP"
heroku run bin/rails features:list --app "$MAT_APP"
heroku ps:scale web=1 worker=1 --app "$MAT_APP"
heroku ps --app "$MAT_APP"
```

With a separate worker, leave `SOLID_QUEUE_IN_PUMA` unset. To run jobs inside Puma instead, set it and omit the separate worker; the Puma config tests variable presence, so setting it to the string `false` still enables the plugin.

Before opening the environment to users, verify staff sign-in and MFA, a [direct upload and download](docs/infrastructure/active_storage_s3_setup.md#verify-upload-and-retrieval), and a [queued email delivery](docs/infrastructure/email_system.md#postmark). If using DocuSeal, complete its [go-live check](docs/development/docuseal_integration_guide.md#go-live-check).

For ongoing operations, keep `MAT_APP` set to the intended app:

| Need | Command |
| --- | --- |
| Migration status | `heroku run bin/rails db:migrate:status --app "$MAT_APP"` |
| Rails console | `heroku run bin/rails console --app "$MAT_APP"` |
| Discover application tasks | `heroku run --app "$MAT_APP" -- bin/rails -T` |
| Worker logs | `heroku logs --tail --dyno worker --app "$MAT_APP"` |
| Recent release output | `heroku releases:output --app "$MAT_APP"` |
| Database status | `heroku pg:info --app "$MAT_APP"` |
| Capture a database backup | `heroku pg:backups:capture DATABASE_URL --app "$MAT_APP"` |

Capture a backup before data repairs or a deliberate template replacement. [PGBackups](https://devcenter.heroku.com/articles/heroku-postgres-backups) covers restore and scheduling; a database backup does not include S3 objects or the encryption keys needed to read encrypted columns.

### Kamal deployment

[config/deploy.yml](config/deploy.yml) is a starting configuration with placeholder server, host, image, and registry values. Set those and the production database, storage, credentials, and integrations before using `bin/kamal deploy`.

The [Dockerfile](Dockerfile) still defaults to Node 22.12.0 and Yarn 1.22.22, while the local frontend setup pins Node 24 and Yarn 4.12.0. Align the container's JavaScript setup before relying on this deployment path.

The configuration enables jobs inside Puma. Its aliases provide `bin/kamal console`, `logs`, `shell`, and `dbc`.

## Maintenance Tasks

Use `bin/rails -T` to discover tasks and read the relevant [task implementation](lib/tasks) before running a data repair.

| Need | Starting point |
| --- | --- |
| Inspect program policies | `bin/rails runner 'pp Policy.order(:key).pluck(:key, :value).to_h'`; [policy management](docs/features/application_workflow_guide.md#program-policies). |
| View or change fulfillment defaults | `bin/rails features:list`; [fulfillment settings](docs/features/application_workflow_guide.md#fulfillment-settings). |
| Investigate duplicate identities | [User management](docs/development/user_management_features.md) and [duplicate reporting tasks](lib/tasks/duplicates.rake). |
| Check database templates | `bin/rails email_templates:audit`; [email and letter commands](docs/infrastructure/email_system.md#seed-and-audit-tasks). |
| Refresh certification delivery status | [Delivery tracking](docs/infrastructure/email_system.md#delivery-tracking). |
| Find approved voucher applications without vouchers | `bin/rails vouchers:report_missing`. |
| Review scheduled work | [Recurring configuration](config/recurring.yml), [proof monitoring limitations](docs/features/proof_review_process_guide.md), and [operational review schedule](docs/compliance/required_reports_audits.md). |

`ruby bin/pre-deploy-checks` prints database/proof diagnostics. It catches errors and reports them in output, so a zero exit status is not a release-readiness gate.

## Contributing

Make a focused change, test the affected behavior, and update the relevant guide when setup or behavior changes. A pull request should explain the result, verification performed, and remaining limitations. Start with the [security baseline](docs/security/baseline_policy.md) when changing access, personal data, or public links.
