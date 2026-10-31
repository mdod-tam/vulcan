# Setup and maintenance

The [project README](../../README.md#installation) covers prerequisites, credentials, local databases, and starting the app. This guide covers environment initialization on PostgreSQL 18 and command-line operations.

`bin/setup` currently passes the unsupported Yarn 1 `--check-files` option and ignores its failure. Use the README's installation and database commands until that script is updated.

## Bootstrapping an environment

`bin/rails db:bootstrap` initializes an empty environment, or one you are deliberately resetting. It is separate from an ordinary release, which only migrates (`release: bin/rails db:migrate`), and from a restore: never rerun it to recover data, because it overwrites staff-edited baseline records.

Provide the human administrator as deployment secrets or configuration, never as repository files:

| Variable | Purpose |
| --- | --- |
| `BOOTSTRAP_ADMIN_EMAIL` | Administrator sign-in address; must differ from the system audit address `system@mdmat.org`. |
| `BOOTSTRAP_ADMIN_FIRST_NAME`, `BOOTSTRAP_ADMIN_LAST_NAME` | Profile name. |
| `BOOTSTRAP_ADMIN_PASSWORD` | Initial password, stored only as a hash. It is never printed or logged. |

The command also needs the normal [production configuration](../../README.md#production-essentials), including persistent Active Record encryption keys in credentials. It never generates or replaces encryption keys, credentials, or `secret_key_base`, and it never accepts the temporary keys that disposable tests use, even with `SECRET_KEY_BASE_DUMMY=1` set. Missing or partial keys stop it before it writes anything.

It runs these steps in order:

1. Validate the administrator inputs before any write.
2. Run the native `db:migrate` for every configured database.
3. In one primary-database transaction: provision the system audit administrator, provision the human administrator, reset the baseline records below, and check that every required record exists, including a clean `email_templates:audit`.
4. After the commit, read everything back with fresh queries and print a completion summary.

| Baseline record | What a run does |
| --- | --- |
| Policies | Sets every [default](../../app/services/baseline/policies.rb) back to its checked-in value, recording a policy change for each difference. |
| Feature flags | Resets `vouchers_enabled` and `dcf_auto_request_certification` to disabled and every communication control to enabled, through `EmailDelivery::ControlWriter` so row identities and cancellation generations are kept. |
| Rejection reasons | Sets the English and Spanish bodies of every [catalog reason](../../app/services/baseline/rejection_reasons.rb) by `(code, proof_type, locale)`, keeping version history, and leaves each pair synchronized. Reasons staff added under other codes are untouched. |
| Email templates | Deletes every template and imports the [checked-in files](../../db/seeds/email_templates) in the same transaction, then audits them. The new rows have new ids, so messages captured under the old rows are refused, and pending letters are reconciled after commit. Staff-edited template copy is lost. |

Accounts follow different rules. The system audit administrator gets a random password that is never shown, only when it is first created. An existing administrator with the configured address, including its password, MFA factors, sessions, and profile, is left exactly as it is, so repeating the command is not a credential rotation. An address that belongs to a constituent, a legacy-typed user, or an inactive, suspended, or merged account stops the run with a conflict; nothing is promoted or reactivated, so resolve it manually and rerun. The new administrator follows the normal first-sign-in [MFA enrollment](../security/authentication_system.md#second-factors); the command creates no factor, invitation, or reset message. `User.system_user` remains lookup-only.

Any failure before the commit rolls back the accounts and baseline changes, though migrations that already ran stay applied; fix the cause and rerun. A failure in the final readback exits nonzero with a message that the changes committed and were not rolled back; rerun the command or run `bin/rails email_templates:audit`. Pause delivery processes first when rerunning against an environment that is already sending: the transaction cannot retract a message already handed to a provider. `db:prepare` alone does not seed, and the container entrypoint only migrates, so a failed attempt is retried through `db:bootstrap`.

## Baseline tasks

Each task runs in one transaction as the system audit administrator and reapplies its checked-in values every time, including when run again in the same process. They need the system audit account that `db:bootstrap` provisions.

| Task | Effect |
| --- | --- |
| `bin/rails db:seed_policies` | Resets program policies: income thresholds, waiting periods, training limits, throttles, secure-link timing, and voucher settings. |
| `bin/rails db:seed_feature_flags` | Resets feature flags and communication controls. |
| `bin/rails db:seed_manual_email_templates` | Replaces every template with the checked-in templates. |
| `bin/rails db:seed_rejection_reasons` | Resets catalog rejection-reason bodies. |

These tasks overwrite staff changes. Routine policy changes belong in the [policy-management workflow](../features/application_workflow_guide.md#program-policies). The general `db:seed` task is the development and test demo seed: it needs FactoryBot and deletes existing records. In production it loads the same initialization as `db:bootstrap`, without the earlier input check or migration, so use `db:bootstrap`.

Products come from [products.yml](../../test/fixtures/products.yml) in the demo seed. There is no standalone product seed task; production products can be entered through the admin product workflow.

The system audit account is required at runtime: without it, public audit events and metrics alerts are skipped, expiration audits remain pending, secure-link recovery cannot issue a replacement without its original requester, certification uploads fail before storage, and DocuSeal callbacks return HTTP 503 for retry. Registrations requiring duplicate review roll back.

## Heroku deployment and operations

The first release that includes the email delivery controls needs sending stopped during the deploy; follow [Releasing the delivery controls](email_system.md#releasing-the-delivery-controls).

Before deploying the [session-activity migration](../../db/migrate/20261022173000_add_last_active_at_to_sessions.rb) to a running instance, schedule a maintenance window: stop web and worker processes and pause scheduled jobs before migration. It signs everyone out, and old code cannot sign users in after the required column is added. Heroku maintenance mode alone does not stop dynos or scheduled jobs; record the current process counts and stop them explicitly. Restore the process counts after the new release is promoted, check sign-in, then reopen traffic. See [Heroku's maintenance guidance](https://devcenter.heroku.com/articles/maintenance-mode#maintenance-mode-and-dynos).

The checked-in [Procfile](../../Procfile) defines web, worker, and release processes. Start with a Heroku app and attached Postgres database; [Heroku's Rails guide](https://devcenter.heroku.com/articles/getting-started-with-rails8#create-a-heroku-app) covers provisioning. Set the [production configuration](../../README.md#production-essentials), including storage and integration credentials, then deploy the intended checkout:

```bash
export MAT_APP=your-app-name
heroku git:remote --app "$MAT_APP"
heroku config:set RAILS_MASTER_KEY=... --app "$MAT_APP"
heroku config:set APPLICATION_HOST=your-public-host --app "$MAT_APP"
git push heroku HEAD:main
heroku releases --app "$MAT_APP"
```

The [release phase](https://devcenter.heroku.com/articles/release-phase) runs `bin/rails db:migrate`; check that it succeeded. For the first deployment of an empty database, set the administrator inputs and run the bootstrap once, before starting web and worker processes:

```bash
heroku config:set BOOTSTRAP_ADMIN_EMAIL=... BOOTSTRAP_ADMIN_FIRST_NAME=... BOOTSTRAP_ADMIN_LAST_NAME=... --app "$MAT_APP"
heroku config:set BOOTSTRAP_ADMIN_PASSWORD=... --app "$MAT_APP"
heroku run bin/rails db:bootstrap --app "$MAT_APP"
heroku config:unset BOOTSTRAP_ADMIN_PASSWORD --app "$MAT_APP"
```

Then check the baseline data and start the web and worker processes:

```bash
heroku run bin/rails email_templates:audit --app "$MAT_APP"
heroku run bin/rails features:list --app "$MAT_APP"
heroku ps:scale web=1 worker=1 --app "$MAT_APP"
heroku ps --app "$MAT_APP"
```

With a separate worker, leave `SOLID_QUEUE_IN_PUMA` unset. To run jobs inside Puma instead, set it to `true` and omit the separate worker.

Check both scan and general job backlogs after deployment. The default worker configuration reserves one thread for document scans and one for general work, including mail; see [scan workers and monitoring](../security/attachment_scanning.md).

Before opening the environment to users, verify staff sign-in and MFA, an [upload, antivirus scan and download](active_storage_s3_setup.md#verify-upload-and-retrieval), and a [queued email delivery](email_system.md#postmark). If using DocuSeal, complete its [go-live check](../development/docuseal_integration_guide.md#go-live-check).

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

Capture a backup before data repairs or a deliberate template replacement. The [backup and recovery guide](backup_and_recovery.md) covers scheduling, retention, restoration on Heroku, and which secrets/settings must match. A database dump excludes uploaded files and encryption keys. Restoring an existing environment does not require `db:bootstrap`; rerunning it replaces recovered policies, flags, rejection reasons, and edited templates.

### Queue schema changes

Solid Queue's tables live in the application database unless `QUEUE_DATABASE_URL` is set, so on Heroku a queue migration runs against the live queue. The tables follow the Solid Queue gem's own schema (`lib/generators/solid_queue/install/templates/db/queue_schema.rb` in the installed gem).

- **Add a new migration; never edit one that has run.** `db:migrate` skips recorded versions, so an edited migration changes new databases but leaves deployed ones as they were. Put queue migrations in `db/queue_migrate`. After upgrading the gem, `bin/rails solid_queue:update` copies its new migration there.
- **Generate `db/queue_schema.rb` from an isolated database, never from a development or deployed one.** In a shared database the dump also contains application tables and any queue tables left over from earlier schemas. Build a throwaway database from the queue migrations alone, with `SCHEMA` naming a file that does not exist yet so Rails migrates from zero and writes the dump there:

  ```bash
  (
    export RAILS_ENV=test DATABASE_URL=postgres://postgres@localhost:5432/queue_scratch \
      QUEUE_DATABASE_URL=postgres://postgres@localhost:5432/queue_scratch_queue \
      CABLE_DATABASE_URL=postgres://postgres@localhost:5432/queue_scratch_cable
    bin/rails db:create
    SCHEMA=tmp/queue_schema.rb bin/rails db:migrate:queue
    bin/rails db:drop
  )
  cp tmp/queue_schema.rb db/queue_schema.rb
  ```

  The subshell keeps the scratch settings out of your session. Compare the result with the gem's template before committing it.
- **Recreate development databases built from an older `db/schema.rb`.** They keep stray `solid_queue_*` tables in the primary database, and a development `db:migrate` dumps schema, so those tables reappear in `db/schema.rb`. Run `bin/rails db:reset` (development only; it discards the data) before migrating, and check that `git diff db/schema.rb` shows no `solid_queue` lines afterwards.
- **Prove the upgrade on a database in the deployed state.** Fresh-database checks do not cover it. Use one scratch database for both `DATABASE_URL` and `QUEUE_DATABASE_URL`, as on Heroku. Load the committed `db/schema.rb` and the previous `db/queue_schema.rb` (`git show HEAD:db/queue_schema.rb`, passed through `SCHEMA` to `db:schema:load:queue`), add jobs and failure rows, run `db:migrate`, and confirm the rows survive and the structure matches the template.

To deploy a queue migration to an existing environment:

1. Capture a backup (`heroku pg:backups:capture DATABASE_URL --app "$MAT_APP"`).
2. Stop the worker (`heroku ps:scale worker=0 --app "$MAT_APP"`). A worker that started before the release keeps the old column list for `solid_queue_*` tables and fails to record job failures once a column is dropped, until it restarts.
3. Deploy. The release phase runs the migration, and a failed release leaves the previous release running. A migration that adds a unique index fails if existing rows break it; `AlignSolidQueueSchemaWithGem` checks first and reports it. Remove the duplicates (keep one row per key) and deploy again.
4. Start the worker (`heroku ps:scale worker=1 --app "$MAT_APP"`) and check `heroku run bin/rails db:migrate:status --app "$MAT_APP"` and `heroku logs --tail --dyno worker --app "$MAT_APP"`.
