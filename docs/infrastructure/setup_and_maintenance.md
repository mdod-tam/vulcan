# Setup and maintenance

The [project README](../../README.md#installation) covers prerequisites, credentials, local databases, and starting the app. This guide covers environment initialization and command-line operations.

`bin/setup` currently passes the unsupported Yarn 1 `--check-files` option and ignores its failure. Use the README's installation and database commands until that script is updated.

## Baseline seeds

These tasks initialize the baseline records for a new environment. Run them after migrations and [initial account setup](#initial-accounts), in the intended Rails environment; for a standalone production install, prefix each command with `RAILS_ENV=production`. The [Heroku sequence](#heroku-deployment-and-operations) runs them against the selected app.

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
system_actor = User.find_by(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
raise 'System audit address belongs to a non-admin; resolve the conflict manually' if system_actor && !system_actor.admin?

system_actor ||= Users::Administrator.create!(
  email: PublicAuditActor::SYSTEM_AUDIT_EMAIL,
  password: SecureRandom.hex(32),
  first_name: 'System',
  last_name: 'User',
  verified: true
)
raise 'System audit account missing' unless PublicAuditActor.system_audit_actor

Users::Administrator.create!(
  email: 'admin@example.org',
  password: 'replace-with-a-secure-password',
  first_name: 'Admin',
  last_name: 'User',
  email_verified: true
)
```

The explicit command above provisions `system@mdmat.org` for audit attribution and refuses to promote a conflicting account. `User.system_user` only looks up an existing administrator; runtime requests and jobs never provision it. Without it, public audit events and metrics alerts are skipped, expiration audits remain pending, secure-link recovery cannot issue a replacement without its original requester, certification uploads fail before storage, and DocuSeal callbacks return HTTP 503 for retry. Registrations requiring duplicate review roll back. Policy seeding stops before making changes. The staff administrator is a separate account and must [enroll in MFA](../security/authentication_system.md#second-factors) on first sign-in.

## Heroku deployment and operations

The first release that includes the email delivery controls needs sending stopped during the deploy; follow [Releasing the delivery controls](email_system.md#releasing-the-delivery-controls).

An upgrade that applies the evaluator `report_submitted` column removal also requires the [maintenance cutover below](#evaluator-workflow-column-removal) before pushing or promoting the release.

The checked-in [Procfile](../../Procfile) defines web, worker, and release processes. Start with a Heroku app and attached Postgres database; [Heroku's Rails guide](https://devcenter.heroku.com/articles/getting-started-with-rails8#create-a-heroku-app) covers provisioning. Set the [production configuration](../../README.md#production-essentials), including storage and integration credentials, then deploy the intended checkout:

```bash
export MAT_APP=your-app-name
heroku git:remote --app "$MAT_APP"
heroku config:set RAILS_MASTER_KEY=... --app "$MAT_APP"
heroku config:set APPLICATION_HOST=your-public-host --app "$MAT_APP"
git push heroku HEAD:main
heroku releases --app "$MAT_APP"
```

The [release phase](https://devcenter.heroku.com/articles/release-phase) runs `bin/rails db:migrate`; check that it succeeded, then use `heroku run bin/rails console --app "$MAT_APP"` for [initial account setup](#initial-accounts). Provision the system audit account before seeding or starting web and worker processes. For the first deployment, run the remaining initialization commands:

```bash
heroku run bin/rails db:seed_policies --app "$MAT_APP"
heroku run bin/rails db:seed_feature_flags --app "$MAT_APP"
heroku run bin/rails db:seed_manual_email_templates --app "$MAT_APP"
heroku run bin/rails db:seed_rejection_reasons --app "$MAT_APP"
```

Then check the baseline data and start the web and worker processes:

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

Capture a backup before data repairs or a deliberate template replacement. The [backup and recovery guide](backup_and_recovery.md) covers scheduling, retention, restoration on Heroku, and which secrets/settings must match. A database dump excludes uploaded files and encryption keys. Restoring an existing environment does not require initialization seeds; rerunning them can replace recovered policies and edited templates.

### Evaluator workflow column removal

For an existing environment that has not applied [20261012120200_remove_report_submitted_from_evaluations](../../db/migrate/20261012120200_remove_report_submitted_from_evaluations.rb), deploy with a maintenance cutover. The old release writes this column during evaluator assignment. Rails also caches column metadata and this app inserts column defaults, so removing explicit references alone does not make a later rolling drop safe. This release removes the dead code and column together; it requires stopping the old processes before the migration runs.

1. Record the current process formation and queue settings, block traffic, and stop old web, worker, embedded Puma queue, additional process and writer one-off processes. Pause independent Scheduler tasks and external writers. Use the existing [stop and resume procedure](vendor_tax_records_cutover.md#pause-and-resume-solid-queue-on-heroku). Verify that the old processes have stopped before pushing or promoting this release. [Maintenance mode](https://devcenter.heroku.com/articles/maintenance-mode) blocks web routing but does not stop these processes.
2. Keep writers stopped while deploying the candidate. The [release phase](https://devcenter.heroku.com/articles/release-phase) runs the checked-in migration before the new application formation starts. Check the release output and `bin/rails db:migrate:status` from the candidate release. Do not rerun initialization seeds during this upgrade.
3. Verify the schema from a fresh candidate process before restoring workers or traffic:

   ```sh
   heroku run --exit-code --app "$MAT_APP" -- bin/rails runner 'abort "Evaluator column removal is pending" if Evaluation.column_names.include?("report_submitted")'
   ```

   Start only processes from the candidate release, with fresh schema metadata. Restore the recorded queue configuration and process formation using the linked resume procedure; restore public traffic last.
4. If the migration fails, keep access and writers stopped until the schema and selected application release are compatible. Once the column is removed, a code-only rollback to the old writer is unsafe. Restore the compatible schema while processes are stopped, or roll forward to a compatible release, before resuming them.

This cutover is required for the first application of the column drop to an existing environment. Later deployments that do not perform this removal do not inherit this requirement.
