# Backup and recovery

A PostgreSQL restore can succeed while Rails cannot decrypt records or retrieve attachments. Recovery requires the database, matching encryption material, uploaded files, and compatible application code/configuration.

This guide describes the recovery procedure; it does not establish that a deployed app has backups configured or that a restore has been tested. Keep secret values, config exports, database dumps, and signed download URLs out of Git and shared logs. Commands below use variable names only.

## Recovery checklist

- [ ] Identify each physical database behind `DATABASE_URL`, `QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`, and `CABLE_DATABASE_URL`. The auxiliary connections [fall back to the primary database](../../config/database.yml) unless overridden; back up each required database once.
- [ ] Record the backup time, deployed release/commit, PostgreSQL version, and required extensions. For a separate Solid Queue database, coordinate its recovery point with the primary database and review pending jobs before resuming them. Cache/cable state can usually be recreated with the required schema.
- [ ] Preserve the credentials file selected by the production release, its decryption key, and environment-provided secrets in the approved secret store. Retain historical encryption keys for as long as retained backups need them.
- [ ] Back up S3 objects independently, with a recovery point compatible with the database's attachment metadata. Preserve object keys, bucket permissions, and any storage-encryption key access. For disk storage, preserve the configured storage directory instead.
- [ ] Record backup frequency, retention, acceptable data loss, and who checks failures. Retain a protected copy outside the lifetime of the Heroku database add-on.
- [ ] Rehearse recovery into an isolated instance and bucket. Verify old encrypted records, authentication, email search, and attachments before enabling outbound integrations or queued jobs.

## Must settings match the original instance?

Names under `active_record_encryption` are Rails credentials entries, not environment variables read directly by [this initializer](../../config/initializers/active_record_encryption.rb).

| Secret or setting | Must match? | Recovery requirement |
| --- | --- | --- |
| `RAILS_MASTER_KEY` / credentials key file | **Yes for the same encrypted credentials file; otherwise no.** | A new master key works only with credentials re-encrypted under that key while preserving the underlying database-encryption keys. The master key does not directly encrypt database columns. |
| `active_record_encryption.primary_key` | **Yes.** | Preserve the key material needed to decrypt the backup's nondeterministic encrypted fields, including password digests and MFA credentials. |
| `active_record_encryption.deterministic_key` | **Yes.** | Preserve it for encrypted contact reads, equality lookups, and uniqueness behavior. |
| `active_record_encryption.key_derivation_salt` | **Yes.** | The same encryption keys with a different salt do not derive the same encryption material. |
| `SECRET_KEY_BASE` / credentials `secret_key_base` | **Yes for continuity.** | Preserve the effective runtime value. Changing it invalidates existing Rails-signed cookies/links and requires rebuilding this app's persisted email-search tokens; it does not replace the Active Record keys. |
| `DATABASE_URL`, `QUEUE_DATABASE_URL`, `CACHE_DATABASE_URL`, `CABLE_DATABASE_URL` | **No.** | Point each connection at the intended restored or recreated database. Database host, username, and password may change. |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` / `BUCKETEER_AWS_ACCESS_KEY_ID`, `BUCKETEER_AWS_SECRET_ACCESS_KEY` | **No.** | Replacement credentials must access the restored objects and any required KMS keys. Keep bucket access private. |
| `S3_BUCKET`, `S3_REGION` / `BUCKETEER_BUCKET_NAME`, `BUCKETEER_AWS_REGION` | **No, if files are copied.** | Preserve each blob's object key and its configured Active Storage service name. Point that service at the restored bucket/region; changing the default service alone does not rewrite existing blob records. |
| `APPLICATION_HOST`, `WEBAUTHN_RP_ID` | **Conditional.** | Keep the original relying-party ID for existing security keys and configure a valid allowed origin. Moving to an unrelated domain can require reenrollment. Update generated links, callback URLs, and S3 CORS for the actual host. |
| Credentials `postmark_api_token` | **No.** | Use authorized credentials for the intended mail service and sender. Isolate delivery during a rehearsal. |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_VERIFY_SERVICE_SID`, `TWILIO_SMS_FROM_NUMBER`, `TWILIO_FAX_FROM_NUMBER` | **Not for database decryption.** | Keep or deliberately migrate the associated account, services, numbers, and callbacks. Replacement credentials do not transfer provider-side state or pending verifications. |
| Credentials `docuseal.api_key`, `docuseal.base_url` | **Not for database decryption.** | Preserve access to the service/account holding existing submissions and documents; a new account does not recreate them. |
| Credentials `webhook_secret` | **Must match the sender.** | Preserve it or coordinate replacement with the webhook sender. Twilio fax callbacks use Twilio's signature verification. |
| `SOLID_QUEUE_IN_PUMA` and worker sizing | **No.** | Keep job execution stopped during restore and inspection. Unset `SOLID_QUEUE_IN_PUMA` before starting a web-only verification process; the variable's presence enables it. |

Rails selects an environment-specific credentials file when present, otherwise the shared file. Preserve the file actually used by the release, not just whichever file is easiest to find. See [Rails credentials configuration](https://guides.rubyonrails.org/configuring.html#config-credentials-content-path).

Do not generate replacement Active Record keys during recovery. `support_unencrypted_data` cannot decrypt ciphertext encrypted with lost keys, and stored key references are not copies of the keys. [PII encryption](../security/pii_encryption.md) lists affected fields. [UserEmailSearch](../../app/models/concerns/user_email_search.rb) owns the HMAC index and `rebuild_email_search_tokens!` if a deliberate `secret_key_base` rotation is necessary.

## Heroku database backups

Heroku's [Continuous Protection](https://devcenter.heroku.com/articles/heroku-postgres-data-safety-and-continuous-protection) provides physical recovery; self-service [point-in-time rollback](https://devcenter.heroku.com/articles/heroku-postgres-rollback) depends on the database plan. PGBackups creates portable logical snapshots. Neither includes this app's S3 objects or Rails secrets. Confirm plan support; Heroku documents PGBackups limits for large/heavily loaded databases and excludes Postgres Advanced.

Set these local shell variables for the intended operation; none are Rails settings:

| Variable | Select locally |
| --- | --- |
| `MAT_SOURCE_APP`, `MAT_RESTORE_APP` | Source app and restore destination. Use a separate destination for rehearsals. |
| `MAT_BACKUP_ID` | A specific completed backup from the source app. |
| `MAT_BACKUP_TIME` | A 24-hour clock hour followed by the full IANA timezone, in the format accepted by `--at`. |
| `MAT_BACKUP_FILE` | Protected download path outside the repository. |

### Capture and inspect

```bash
heroku pg:info --app "$MAT_SOURCE_APP"
heroku pg:backups:capture DATABASE_URL --app "$MAT_SOURCE_APP"
heroku pg:backups --app "$MAT_SOURCE_APP"
heroku pg:backups:info "$MAT_BACKUP_ID" --app "$MAT_SOURCE_APP"
```

Select the completed backup ID from the listing and confirm its database and timestamp. For another physical database, replace `DATABASE_URL` with its attachment name. See [PGBackups](https://devcenter.heroku.com/articles/heroku-postgres-backups).

### Schedule, change, or stop daily backups

```bash
heroku pg:backups:schedule DATABASE_URL --at "$MAT_BACKUP_TIME" --app "$MAT_SOURCE_APP"
heroku pg:backups:schedules --app "$MAT_SOURCE_APP"
```

To change the hour/timezone, remove the old schedule, update `MAT_BACKUP_TIME`, then run the schedule and verification commands again. To stop daily backups, run only:

```bash
heroku pg:backups:unschedule DATABASE_URL --app "$MAT_SOURCE_APP"
```

Repeat for each separate database requiring a backup. Check backup completion: scheduled failures do not generate notifications. Verify schedules again after restoring, promoting, or changing database attachments. Retention is plan-defined; longer retention needs separately stored copies. See [scheduled backups and retention](https://devcenter.heroku.com/articles/heroku-postgres-backups#scheduled-backups).

### Keep an independent copy

```bash
umask 077
heroku pg:backups:download "$MAT_BACKUP_ID" --output "$MAT_BACKUP_FILE" --app "$MAT_SOURCE_APP"
```

Move the dump into approved encrypted backup storage with restricted access. Field encryption covers only selected columns; the dump still contains sensitive unencrypted data. Keep decryption keys separately recoverable. Do not commit the dump or a config export. Command options are in the [Heroku CLI reference](https://devcenter.heroku.com/articles/heroku-cli-commands#heroku-pg-backups-download-backup-id).

## Restore on Heroku

### Prepare the destination

- [ ] Confirm the source backup and destination database. **Restore replaces the destination database's contents.** Prefer a new instance; capture a safety backup before replacing an existing database.
- [ ] Provision compatible Postgres and deploy the matching application release with the required secrets and storage access. The [release process](../../Procfile) runs migrations: do not deploy an unreviewed newer schema as part of recovery.
- [ ] Record the destination's process formation. Stop writers, including web/worker processes, Scheduler tasks, and one-off jobs. Pause automatic deployments and isolate outbound providers during a rehearsal. Maintenance mode alone does not stop background work.

For an app supporting [Heroku maintenance mode](https://devcenter.heroku.com/articles/maintenance-mode):

```bash
heroku maintenance:on --app "$MAT_RESTORE_APP"
heroku ps --app "$MAT_RESTORE_APP"
heroku ps:scale web=0 worker=0 --app "$MAT_RESTORE_APP"
```

Stop any additional process types too. On Fir, use the supported traffic controls instead of maintenance mode. Scaling web to zero in Private Spaces prevents its maintenance page from being served; account for that outage behavior. Stopping web also stops jobs embedded in Puma.

- [ ] Restore files into the intended private bucket, retaining object keys. Use a separate bucket for rehearsals so test actions cannot delete production attachments.
- [ ] Configure the matching encryption keys and effective `secret_key_base` before starting Rails. The current initializer can generate temporary keys when configuration is missing; successful boot alone is not proof of recoverability.

### Restore the selected backup

This selects the source explicitly and restores into the destination app's primary database:

```bash
heroku pg:backups:restore "$MAT_SOURCE_APP::$MAT_BACKUP_ID" DATABASE_URL --app "$MAT_RESTORE_APP"
heroku pg:backups --app "$MAT_RESTORE_APP"
heroku pg:info --app "$MAT_RESTORE_APP"
```

Check the restore's completion in the backup listing. Restore any separate required database using its matching backup ID and destination attachment. Leave Heroku's confirmation prompt enabled. See the [restore command](https://devcenter.heroku.com/articles/heroku-cli-commands#heroku-pg-backups-restore-backup-database).

For an independently stored custom-format dump, use a short-lived signed URL in the local variable `MAT_RESTORE_URL` instead of the source-app/backup-ID argument. Keep the bucket private and the URL out of Git, logs, and shared transcripts. Heroku's [import instructions](https://devcenter.heroku.com/articles/heroku-postgres-import-export#import) describe the supported format and URL requirements.

### Verify before reopening

- [ ] Check migration status against the intended release. Apply only migrations required for that release after the restore; a deploy that ran migrations before restoration does not prove the restored schema is current.
- [ ] Read pre-backup encrypted records through Rails without printing personal data. Verify designated accounts' contact lookup, password sign-in, MFA, and admin email search. Newly created test records alone cannot prove old data is decryptable.
- [ ] Download pre-backup attachments and verify a new upload against the restored storage service.
- [ ] Review pending jobs and external delivery state before restarting workers. An older snapshot can restore jobs whose real-world effects already happened, including email/SMS deliveries.
- [ ] Keep restored policies, templates, and accounts. **Do not run initialization seeds:** policy seeding overwrites differing values, template seeding replaces edited copy, and demo seeding clears data.
- [ ] Restore the intended process formation and traffic only after validation. Disable maintenance mode when applicable, verify backup schedules on the recovered database, and record the restore result without secrets or personal data.

Use `heroku run bin/rails db:migrate:status --app "$MAT_RESTORE_APP"` for the schema check. For browser verification, start web with workers stopped and `SOLID_QUEUE_IN_PUMA` unset, with access restricted to the recovery team. Preserve isolation of outbound services until delivery tests and queued work have been reviewed.
