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
- **Back up or restore:** [recovery checklist, matching keys, and Heroku commands](docs/infrastructure/backup_and_recovery.md).

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

- **A user and an application are different records.** A user is a person/account; an application is one request for assistance. Roles share the `users` table through STI: `Users::Constituent`, `Users::Administrator`, `Users::Vendor`, `Users::Evaluator`, `Users::Trainer`, and `Users::CertifyingProfessional`.
- **Applicant, guardian, and message recipient can differ.** A guardian relationship is distinct from an application's managing guardian. Contact ownership and public-login eligibility have separate rules; see [guardian relationships](docs/development/guardian_relationship_system.md) and [authentication](docs/security/authentication_system.md).
- **Lifecycle changes have side effects.** Use `Application#transition_status!` and `Application#reconcile_workflow_state!` to preserve status history and associated work. Application status, individual proof decisions, and disability certification are separate states; `Application#transition_disability_certification_status!` is the one writer of the certification status.
- **Fulfillment is saved on each application.** At creation, `vouchers_enabled` determines voucher versus equipment fulfillment and whether income proof is required. Changing the flag does not rewrite existing applications; see [fulfillment settings](docs/features/application_workflow_guide.md#fulfillment-settings).
- **History has several owners.** `Event`, `ApplicationStatusChange`, `ProofReview`, and `Notification` answer different questions. Use the [audit guide](docs/features/audit_event_tracking.md) and [notification guide](docs/features/notifications.md) when tracing an outcome.
- **Paper context is intake state, not a proof-validation bypass.** `Current.paper_context` relaxes selected contact validations and tells the proof attachment service that paper intake owns reconciliation and delivery. It is scoped by paper-intake entry points. See [paper intake](docs/development/paper_application_architecture.md) before reusing that context.

## Documentation

The [documentation hub](docs/README.md) is the guide index. It covers workflows, architecture, testing, integrations, security, and operational reviews. Planned work is labeled separately from descriptions of current behavior.

## Technical Stack

Ruby 4.0.9 and Rails 8.1.4; PostgreSQL; ERB, Turbo, Stimulus, Tailwind, esbuild, and Propshaft; Solid Queue, Solid Cache, and Solid Cable; Active Storage; Minitest/FactoryBot, Cuprite, and Jest.

External integrations are Postmark for email, Twilio for SMS/fax status handling, DocuSeal for signing, and S3-compatible storage in production. Development uses local file storage and Letter Opener for email.

## Prerequisites

- Ruby from [`.ruby-version`](.ruby-version) and Bundler.
- PostgreSQL 18, which production and development use and CI tests against. A `pg_dump` used for backups or schema work must have a major version at least equal to the server's.
- Node.js 24.x (see [`.node-version`](.node-version)) and Corepack. `packageManager` in [package.json](package.json) selects Yarn 4.12.0; [`.yarnrc.yml`](.yarnrc.yml) retains the `node-modules` linker.
- libvips for Active Storage image representations: `brew install vips` on macOS, or `sudo apt-get install libvips42t64` on Ubuntu 24.04/26.04. The `image_processing` and `ruby-vips` gems use this native library; Bundler does not install it. See [image processing setup](docs/infrastructure/active_storage_s3_setup.md#image-processing-prerequisites).
- Chrome or Chromium when running browser tests.
- The team credentials key, or an isolated development/test credentials setup as described below.

## Installation

For a local chruby setup, install and select the pinned Ruby before installing gems:

```bash
ruby-install ruby 4.0.9
chruby ruby-4.0.9
```

```bash
git clone https://github.com/mdod-tam/vulcan.git
cd vulcan
bundle install
corepack enable
yarn --version
yarn install --immutable
```

`yarn --version` should print `4.12.0`. If Corepack is missing, install it with `npm install --global corepack`, then run `corepack enable`. If a global Yarn launcher still selects another version, use `corepack yarn install --immutable` and correct the launcher in your `PATH`. Keep `packageManager` as the version source; immutable installs preserve `yarn.lock`.

`bin/setup` currently passes the unsupported Yarn 1 `--check-files` option and ignores its failure. Use the installation and database commands here until that script is updated.

### Credentials

For shared credentials, obtain the matching key from a maintainer and place it in `config/master.key` or export `RAILS_MASTER_KEY`. Generating a new key will not decrypt the existing `config/credentials.yml.enc`.

For an isolated local setup with fresh or disposable data, create environment-specific credentials without replacing the shared encrypted file:

```bash
EDITOR="vim" bin/rails credentials:edit --environment development
EDITOR="vim" bin/rails credentials:edit --environment test
```

Use `bin/rails db:encryption:init` to generate the `active_record_encryption` entries, then add all three entries to each local credentials file before saving data. Keep these keys stable across restarts and keep local keys and credentials out of your change.

Normal development and other non-test runtimes refuse missing, incomplete or blank encryption credentials. Encrypted attributes reject plaintext stored values. Temporary keys are limited to disposable tests. Secretless asset precompilation does not generate encryption keys. See [PII encryption](docs/security/pii_encryption.md).

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

### Baseline tasks

`bin/rails db:bootstrap` initializes an empty environment (see [bootstrapping an environment](docs/infrastructure/setup_and_maintenance.md#bootstrapping-an-environment)); it migrates, provisions the system audit account and one staff administrator from `BOOTSTRAP_ADMIN_*` inputs, and resets the baseline records. It overwrites staff-edited baseline data. These tasks reapply one part of that baseline with the same overwrite behavior, and need the system audit account it provisions:

| Task | Effect |
| --- | --- |
| `bin/rails db:seed_policies` | Resets program policies: income thresholds, waiting periods, training limits, throttles, secure-link timing, and voucher settings. |
| `bin/rails db:seed_feature_flags` | Resets feature flags and communication controls; `vouchers_enabled` defaults to disabled. |
| `bin/rails db:seed_manual_email_templates` | Replaces every email and letter template with the checked-in templates. |
| `bin/rails db:seed_rejection_reasons` | Resets catalog proof/certification rejection reasons. |

Review the [policy defaults](app/services/baseline/policies.rb) before initializing. Routine policy changes belong in the [policy-management workflow](docs/features/application_workflow_guide.md#program-policies). The general `db:seed` task is the demo seed for development/test; it depends on FactoryBot and clears existing records.

Products come from [products.yml](test/fixtures/products.yml) in the demo seed. There is no standalone product seed task; production products can be entered through the admin product workflow.

### Initial accounts

`bin/rails db:bootstrap` provisions the system audit account and a separate staff administrator from `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_FIRST_NAME`, `BOOTSTRAP_ADMIN_LAST_NAME`, and `BOOTSTRAP_ADMIN_PASSWORD`, and refuses to promote a conflicting account. `User.system_user` is lookup-only; runtime requests and jobs do not create or promote accounts for audit attribution.

The staff administrator must [enroll in MFA](docs/security/authentication_system.md#second-factors) on first sign-in.

## Running the App

```bash
bin/dev
```

Open [localhost:3000](http://localhost:3000). [Procfile.dev](Procfile.dev) starts Rails, JavaScript and CSS watchers, and a Solid Queue worker. Development email opens through Letter Opener. DocuSeal signing and Twilio delivery need their own configuration when exercising those integrations.

`bin/rails server` starts only the web process. If you use it, build assets with `yarn build` and `yarn build:css`, and run `bin/rails solid_queue:start` separately for queued work. A successful page load does not mean background deliveries or recurring jobs are running.

## Default Development Users

After the demo seed, these accounts use `password1234`:

| Role | Email |
| --- | --- |
| Administrator | `admin@example.com` |
| Constituents | `user@example.com`, `user2@example.com` |
| Trainer | `trainer@example.com` |
| Evaluator | `evaluator@example.com` |
| Vendors | `ray@testemail.com`, `teltex@testemail.com` |
| Legacy certifying-professional seed | `medical@example.com` |

Providers use secure certification links in the current workflow; they do not need a portal account.

Development seeding also adds 16 applicants from ages 12–83, including English- and Spanish-speaking applicants and two guardian-managed dependents. Their applications cover every status, pending and rejected proofs, certification review, and approved applications awaiting training or evaluation. These examples follow the current equipment/voucher feature flags and are excluded from test seeding.

Use `maya.brooks@example.com` for a draft, `lucia.rivera@example.com` for pending proof review, `omar.hassan@example.com` for a rejected ID, `samuel.reed@example.com` for approval, or `isabel.perez@example.com` for a guardian account. All use `password1234`. The complete scenario list is in [development_applications.rb](db/seeds/development_applications.rb).

## Testing

Start with a focused test, then expand to the affected area:

```bash
bin/rails test test/models/user_contact_predicates_test.rb
yarn test test/javascript/controllers/document_upload_controller_test.js --runInBand
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

Set `RAILS_MASTER_KEY`, `DATABASE_URL`, and `APPLICATION_HOST` (the public hostname used in generated links and WebAuthn). Use stable Active Record encryption keys in credentials. Production uses HTTPS and S3-backed uploads. `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN` are required at production startup, except during asset compilation; provisioning the Heroku add-on supplies both.

`QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`, and `CABLE_DATABASE_URL` can override the auxiliary database connections; each otherwise falls back to `DATABASE_URL`. See [database.yml](config/database.yml), [Puma configuration](config/puma.rb), and [queue configuration](config/queue.yml) for connection pools and worker sizing.

### Integrations

| Integration | Configuration owner |
| --- | --- |
| Postmark | `postmark_api_token` in Rails credentials; [email and letters guide](docs/infrastructure/email_system.md). |
| DocuSeal | Credentials `docuseal.api_key` and optional `docuseal.base_url`; register the webhook URL in the DocuSeal console and store its generated `whsec_...` HMAC secret as top-level credentials `webhook_secret`; [setup, signature verification, and host changes](docs/development/docuseal_integration_guide.md). |
| Twilio | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_SMS_FROM_NUMBER`, `TWILIO_VERIFY_SERVICE_SID`, and `TWILIO_FAX_FROM_NUMBER` as needed; [initializer](config/initializers/twilio.rb). |
| Webhooks | Rails credentials `webhook_secret` supply the HMAC key; DocuSeal verifies its timestamped signature, and Twilio fax callbacks use Twilio's signature. See [webhook controllers](app/controllers/webhooks). |
| S3 uploads | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_REGION`, `S3_BUCKET`, or their Bucketeer alternatives; [storage guide](docs/infrastructure/active_storage_s3_setup.md). |
| AttachmentScanner | `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN`; [scanning, worker queues, and recovery](docs/security/attachment_scanning.md). |

Development boots without scanner credentials. Testing real uploads requires both scanner variables and a running worker; an unavailable scanner leaves uploads blocked. Development application seeds use fixed synthetic fixtures, so browsing those examples does not require a paid scan.

## Deployment

### Heroku-style deployment

The checked-in [Procfile](Procfile) defines web, worker, and release processes. Start with a Heroku app and attached Postgres database; [Heroku's Rails guide](https://devcenter.heroku.com/articles/getting-started-with-rails8#create-a-heroku-app) covers provisioning. Set the [production configuration](#production-essentials), including storage and integration credentials.

Keep `heroku/nodejs` before `heroku/ruby` so asset builds use Yarn selected by `packageManager`. Verify libvips in the target runtime before release. See [native-library checks and the development-first rollout](docs/infrastructure/active_storage_s3_setup.md#image-processing-prerequisites).

The Node buildpack installs dependencies, then Rails' `assets:precompile` builds JavaScript and CSS. The `heroku-postbuild` script defers asset compilation to Rails. Set `SKIP_YARN_INSTALL=1` on existing Heroku apps during deployment to skip the Rails tasks' repeated installs; new apps created from [app.json](app.json) receive this setting and buildpack order. See [the asset-build rollout](docs/infrastructure/setup_and_maintenance.md#heroku-asset-build).

Heroku selects Ruby 4.0.9 from `Gemfile.lock` during the next build; chruby is only for local Ruby selection. Keep `.ruby-version`, the Gemfile Ruby requirement, the lockfile Ruby version, and Docker's Ruby build argument aligned. CI reads `.ruby-version`.

For a running instance, follow the [session-migration maintenance window](docs/infrastructure/setup_and_maintenance.md#heroku-deployment-and-operations): stop old web and worker processes and pause scheduled jobs until the migration finishes and the new release is promoted. Everyone must sign in again afterward.

Deploy the intended checkout:

```bash
export MAT_APP=your-app-name
heroku git:remote --app "$MAT_APP"
heroku config:set RAILS_MASTER_KEY=... --app "$MAT_APP"
heroku config:set APPLICATION_HOST=your-public-host --app "$MAT_APP"
git push heroku HEAD:main
heroku releases --app "$MAT_APP"
```

The [release phase](https://devcenter.heroku.com/articles/release-phase) runs `bin/rails db:migrate`; check that it succeeded. For the first deployment of an empty database, set the `BOOTSTRAP_ADMIN_*` inputs and run `heroku run bin/rails db:bootstrap --app "$MAT_APP"` once before starting web and worker processes, then unset `BOOTSTRAP_ADMIN_PASSWORD`; see [bootstrapping an environment](docs/infrastructure/setup_and_maintenance.md#bootstrapping-an-environment).

Then check the baseline data and start the web and worker processes:

```bash
heroku run bin/rails email_templates:audit --app "$MAT_APP"
heroku run bin/rails features:list --app "$MAT_APP"
heroku ps:scale web=1 worker=1 --app "$MAT_APP"
heroku ps --app "$MAT_APP"
```

With a separate worker, leave `SOLID_QUEUE_IN_PUMA` unset. To run jobs inside Puma instead, set it to `true` and omit the separate worker.

Before opening the environment to users, verify staff sign-in and MFA, a [scanned upload and private download](docs/infrastructure/active_storage_s3_setup.md#verify-upload-and-retrieval), and a [queued email delivery](docs/infrastructure/email_system.md#postmark). If using DocuSeal, complete its [go-live check](docs/development/docuseal_integration_guide.md#go-live-check).

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

Capture a backup before data repairs or a deliberate template replacement. Use the [backup and recovery guide](docs/infrastructure/backup_and_recovery.md) to configure schedules, retain copies, and restore on Heroku.

### Backup and recovery

A database dump alone is insufficient: retain uploaded files, the production credentials file and its decryption key, and the effective `secret_key_base`. The Active Record encryption keys and salt must match the restored data. `RAILS_MASTER_KEY` may differ only if the credentials are re-encrypted under it while preserving those underlying keys.

Follow the [settings comparison and recovery checklist](docs/infrastructure/backup_and_recovery.md#must-settings-match-the-original-instance). Stop jobs during recovery, validate existing encrypted records and attachments, and do not rerun initialization seeds. Keep secret values, database dumps, and config exports out of Git.

### Kamal deployment

[config/deploy.yml](config/deploy.yml) is a starting configuration with placeholder server, host, image, and registry values. Set those and the production database, storage, credentials, and integrations before using `bin/kamal deploy`.

The [Dockerfile](Dockerfile) installs the Node version pinned by [`.node-version`](.node-version) and the checked-in Yarn 4 release, matching the local frontend setup.

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
