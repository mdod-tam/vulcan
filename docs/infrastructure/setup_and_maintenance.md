# Setup and maintenance

The [project README](../../README.md#installation) covers prerequisites, credentials, local databases, and starting the app. This guide covers environment initialization and command-line operations.

`bin/setup` currently passes the unsupported Yarn 1 `--check-files` option and ignores its failure. Use the README's installation and database commands until that script is updated.

## Baseline seeds

These tasks initialize the baseline records for a new environment. Run them after migrations, in the intended Rails environment; for a standalone production install, prefix each command with `RAILS_ENV=production`. The [Heroku sequence](#heroku-deployment-and-operations) runs them against the selected app.

| Task | Effect |
| --- | --- |
| `bin/rails db:seed_policies` | Initializes program policy defaults: income thresholds, waiting periods, training limits, throttles, secure-link timing, and voucher settings. |
| `bin/rails db:seed_feature_flags` | Creates missing flags; `vouchers_enabled` defaults to disabled. |
| `bin/rails db:seed_manual_email_templates` | Loads the checked-in email and letter templates; deletes existing `EmailTemplate` rows first. |
| `bin/rails db:seed_rejection_reasons` | Adds missing proof/certification rejection reasons. |

Review [policy defaults](../../lib/tasks/seed_policies.rake) during initialization. If rows already exist, this task updates differing values; routine policy changes belong in the [policy-management workflow](../features/application_workflow_guide.md#program-policies). Rerunning the template seed replaces staff-edited copy. The general `db:seed` task is for development/test, depends on FactoryBot, and skips its main seed body in production.

Products come from [products.yml](../../test/fixtures/products.yml) in the demo seed. There is no standalone product seed task; production products can be entered through the admin product workflow.

## Initial accounts

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

`User.system_user` provisions `system@mdmat.org` for audit attribution. Public requests deliberately do not create it: without it, public audit events are skipped and registrations requiring duplicate review roll back. The staff administrator is a separate account and must [enroll in MFA](../security/authentication_system.md#second-factors) on first sign-in.

## Heroku deployment and operations

The checked-in [Procfile](../../Procfile) defines web, worker, and release processes. Start with a Heroku app and attached Postgres database; [Heroku's Rails guide](https://devcenter.heroku.com/articles/getting-started-with-rails8#create-a-heroku-app) covers provisioning. Set the [production configuration](../../README.md#production-essentials), including storage and integration credentials, then deploy the intended checkout:

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

Before opening the environment to users, verify staff sign-in and MFA, a [direct upload and download](active_storage_s3_setup.md#verify-upload-and-retrieval), and a [queued email delivery](email_system.md#postmark). If using DocuSeal, complete its [go-live check](../development/docuseal_integration_guide.md#go-live-check).

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
