# Vendor tax records and onboarding deployment

This release has two schema migrations. It keeps Active Storage as the document store and retains reviewed W9s in the vendor's internal `w9_archive`. W9 approval and program authorization remain separate decisions.

## Deployment order

1. **Verify stable keys before deploying or running release migrations.** Configure the existing `active_record_encryption.primary_key`, `deterministic_key`, and `key_derivation_salt` in production credentials on every web, worker, release and operator process. Run `RAILS_ENV=production bin/rails vendor_tax_records:check_keys` from the candidate release image with the intended production credentials before promoting it. The check never prints keys. Confirm that the candidate can read a designated previously encrypted user without printing its personal fields; presence alone does not prove that the keys match. Preserve `secret_key_base` for existing signed references and sessions, and include both sets of credentials in the restore procedure. Do not generate replacement keys for this release. Production boot refuses missing or incomplete keys. Temporary keys are allowed only for the exact Docker asset-build invocation `SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`.
2. **Pause access and durable writers.** Follow the process/scheduler commands below, block uploads and storage retrieval at the deployment's access controls, and pause independent Scheduler entries or external writers. Record the cutover timestamp in UTC only after writers and in-flight uploads have stopped. Back up the stopped database, its corresponding storage objects and the matching credentials. Keep access restricted until storage-key deletion, cache invalidation and verification finish. Heroku maintenance mode covers Rails requests; it does not invalidate a previously issued S3 service URL or a cached response.
3. **Deploy with migrations before traffic.** The checked-in [Procfile](../../Procfile) runs `release: bin/rails db:migrate`: on Heroku, pushing/promoting the release runs the two migrations before the new application formation starts. Step 1 must therefore precede that push/promotion. Check the release output and migration status before continuing. On an installation without that release phase, run `RAILS_ENV=production bin/rails db:migrate` from the candidate release with stable keys, then start the matching application code while access and jobs remain paused. The migrations are `20261009120000_protect_business_tax_ids` (text column, unused nonunique index removed) and `20261009120100_bind_w9_reviews_to_documents` (restrictive blob foreign key, unique vendor/document index, no implicit approval default). Unknown historical documents stay NULL; today's W9 is never inferred as an old reviewed document.
4. **Complete the resumable tasks below.** New writes encrypt TINs at `User`, audit copies remain encrypted by `Event#change_values`, and plaintext reads allow the bounded conversion. The new W9 uploader issues vendor-bound references; authorized downloads stream privately through Rails. Complete protection/key rotation and TIN conversion, then invalidate cached W9 responses at every proxy/CDN. Verify deletion of old file, preview and variant keys; private bucket settings alone do not revoke signed service URLs.
5. **Update existing approval copy and verify.** An administrator must complete the English/Spanish template step below after deploying and before resuming mail jobs or public access. Complete the model/storage/browser checks below using synthetic verification records. Production vendor terms remain unavailable until approved nonempty content is explicitly published.
6. **Resume the recorded formation.** Restore recurring scheduling and job processing only after verification; keep web-only verification isolated from background work. Restore public access last. Record the deployed release, completed cursors, cache invalidation and verification outcome without secrets or personal data.

### Pause and resume Solid Queue on Heroku

This repository uses `worker: bin/rails solid_queue:start`, which starts the worker/dispatcher/scheduler supervisor. `config/recurring.yml` schedules `cleanup_unattached_uploads` at 05:00 UTC. The installed Solid Queue 1.7 supports `SOLID_QUEUE_SKIP_RECURRING=true`, read when the supervisor starts; it omits the scheduler. It does **not** stop already enqueued cleanup or purge jobs. The cutover also changes attachment keys, so stop job execution as well as scheduling. Do not attempt to delete a static recurring-task database row to pause it; this schedule is loaded from the repository at supervisor startup.

For the Heroku deployment described in [setup and maintenance](setup_and_maintenance.md#heroku-deployment-and-operations), record the current formation and these two nonsecret settings, then pause:

```sh
export MAT_APP=your-app-name
heroku ps:scale --app "$MAT_APP"
heroku ps --app "$MAT_APP"
heroku config:get SOLID_QUEUE_IN_PUMA --app "$MAT_APP"
heroku config:get SOLID_QUEUE_SKIP_RECURRING --app "$MAT_APP"
heroku maintenance:on --app "$MAT_APP"
heroku ps:scale web=0 worker=0 --app "$MAT_APP"
heroku config:set SOLID_QUEUE_SKIP_RECURRING=true --app "$MAT_APP"
heroku config:unset SOLID_QUEUE_IN_PUMA --app "$MAT_APP"
heroku ps --app "$MAT_APP"
```

Scale each additional process type to zero with `heroku ps:scale TYPE=0 --app "$MAT_APP"`, replacing `TYPE` with its recorded name. Stop previously listed writer/purge one-offs with `heroku ps:stop --dyno-name run.EXACT_ID --app "$MAT_APP"`, using their actual IDs. Disable independently configured Heroku Scheduler tasks and automatic deploys for the window. Verify no old web/worker/scheduler or one-off writer remains before recording `CUTOVER_AT`. Configuration changes create a release and restart dynos; keep the formation at zero through those changes. Setting `SOLID_QUEUE_IN_PUMA=false` is insufficient: `config/puma.rb` enables the embedded supervisor whenever the variable is present.

A web-only verification process may then run with `worker=0`, `SOLID_QUEUE_IN_PUMA` absent and recurring scheduling still skipped. Restrict its traffic to the recovery team. Keep existing queued jobs; stopping processes does not delete them. Review pending cleanup/purge and external-delivery work before restoring workers. Other deployments must stop all supervisors, including the embedded supervisor enabled in the checked-in Kamal example, and set the same scheduling guard in their process environment before restart.

After all cutover and template checks, restore `SOLID_QUEUE_SKIP_RECURRING` to its recorded value (unset it if originally absent). For the documented separate-worker formation, keep `SOLID_QUEUE_IN_PUMA` absent. The following is an example only when the recorded formation was web=1/worker=1 and the scheduling guard was absent:

```sh
heroku config:unset SOLID_QUEUE_SKIP_RECURRING --app "$MAT_APP"
heroku ps:scale web=1 worker=1 --app "$MAT_APP"
heroku ps --app "$MAT_APP"
heroku logs --dyno worker --app "$MAT_APP"
heroku maintenance:off --app "$MAT_APP"
```

Verify the matching protected release is running and no storage deletion checkpoint remains before opening public access. If recurring scheduling is enabled in the restored formation, verify its scheduler loaded `cleanup_unattached_uploads`. For a deployment that deliberately runs jobs in Puma, restore its recorded `SOLID_QUEUE_IN_PUMA` value only at this final resume step, and do not also start an unintended separate supervisor. [Solid Queue recurring-task documentation](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#recurring-tasks), [Heroku process/config command reference](https://devcenter.heroku.com/articles/heroku-cli-commands#heroku-ps-scale), and [release-phase behavior](https://devcenter.heroku.com/articles/release-phase) describe these controls.

## Resumable tasks

Encrypt legacy TIN columns and historical audit copies in bounded batches:

```sh
RAILS_ENV=production BATCH_SIZE=100 bin/rails vendor_tax_records:backfill
```

The task prints `AFTER_USER_ID` and `AFTER_EVENT_ID`. Resume from the last reported completed batch with those environment variables. It preserves profile timestamps, W9 state, and event history. It is safe to restart from zero. If there are no legacy values, it has no conversion work to do. Do not run `db:reset` against durable data; seeds already write synthetic TINs through the model encryption owner.

Protect existing attachments and invalidate service URLs while writes and cleanup remain paused:

```sh
RAILS_ENV=production WRITES_PAUSED=1 CUTOVER_AT=2026-10-09T16:00:00Z \
  BATCH_SIZE=100 bin/rails vendor_tax_records:protect_w9
```

Use the actual recorded timestamp, not the example. Run this command in the protected release image; on Heroku use a one-off command such as:

```sh
export MAT_W9_CUTOVER_AT=2026-10-09T16:00:00Z
heroku run --exit-code --app "$MAT_APP" -- env WRITES_PAUSED=1 CUTOVER_AT="$MAT_W9_CUTOVER_AT" \
  BATCH_SIZE=100 bin/rails vendor_tax_records:protect_w9
```

Replace the example timestamp with the recorded value before running. `--exit-code` propagates the remote task failure to the Heroku command. `WRITES_PAUSED=1` is an operator acknowledgement, not an automatic process or storage pause. Complete the pause procedure first.

The task follows vendor → secure-request → blob lock order, protects current/retained/known-reviewed files and derivatives, and copies objects to new keys without changing blob IDs or creation times. An old-key checkpoint commits before deletion; on failure, a retry completes deletion without rotating again. Application disk routes recognize those checkpoints and deny old keys.

### Incomplete protection batches

A missing storage object, conflicting document owner or other per-file failure does not prevent the task from processing healthy files and later vendors. It reports only `FAILED vendor_id=... blob_id=... error=...`, then reports `AFTER_VENDOR_ID` and `AFTER_STAGED_BLOB_ID`. Each cursor independently stops at the last uninterrupted successful prefix before its first failed owner/blob; a later healthy file does not move that cursor past a failure. If any file failed, the task exits **nonzero** with an incomplete-cutover message after the scan. Progress output and successful rotations are not proof that the cutover finished.

Keep access, uploads and all cleanup/purge jobs paused. Investigate the reported record IDs under restricted operator access. Restore a missing object from the corresponding storage backup using the database's recorded key/checkpoint; reconcile a conflicting vendor/document reference against trusted attachment and review records before repairing it. Do not relabel a blob owner simply to bypass the guard, clear an old-key checkpoint while the object remains, or manually force either cursor past a failed row. Retain the reported IDs/error classes and safe cursors in the deployment record without document contents or object keys.

After repairing the cause, repeat `protect_w9` with the **same `CUTOVER_AT`** and the printed `AFTER_VENDOR_ID` / `AFTER_STAGED_BLOB_ID` as environment variables. Completed healthy files may be visited again: the existing rotation/checkpoint metadata makes that retry idempotent. Require a zero exit and no remaining failures/checkpoints, then verify deleted old keys and cache invalidation before resuming. An old service URL can continue working while its object remains, even if other files rotated successfully.

Old generic staged-upload references have no trustworthy vendor identity or document purpose. During cutover, pre-cutover unattributed unattached uploads are quarantined and their service keys rotated. They remain stored until the existing seven-day cleanup deadline; their references cannot be submitted or retrieved. Users must reselect these files, including other document types staged before cutover. This protects possible W9 uploads without guessing from a filename. Vendor-bound staged W9 references keep their original signed reference and seven-day deadline. Do not run the task while an upload is writing an old key.

Already downloaded copies and copies retained by a browser or third party cannot be recalled. Application authorization cannot invalidate those copies. Key rotation removes access to old storage objects; cache invalidation addresses cached responses. Neither operation changes historical decisions.

## Verify before restoring access

- Read a previously encrypted user and a newly encrypted TIN through the model; confirm raw TIN columns and audit change copies contain ciphertext. Inspect parameter filtering and audit-error logs using synthetic values only. Check blank profile/admin edits preserve the tax ID, and new invoice PDFs omit it. Existing invoice PDFs are not regenerated by this release.
- Approve a specific pending W9, replace it, and verify the historical decision still opens the retained file. Attempt a stale or repeated decision; confirm the review/status/rejection count/audit remain unchanged. Confirm delivery failure leaves the decision recorded and its delivery outcome visible in the review screen.
- Test administrator access to current and retained W9s, vendor access to its current/usable staged file, another vendor's denial, and logged-out denial. Test copied ordinary blob/proxy/representation/disk URLs and pre-cutover service URLs. Check no old-key checkpoints remain for processed objects, then verify old keys no longer exist and cache invalidation is complete.
- Confirm Today/This Week/This Month/custom filters use Eastern `processed_at` boundaries, pagination preserves the filters, and CSV/count/totals agree. Invalid custom dates must yield an error and refuse CSV export.
- Confirm the genuine pending-vendor acceptance flow passes through upload, document review, separate authorization, redemption retry, invoicing/payment, later shipment tracking, and constituent/guardian visibility. Browser tests use test-only terms content; production remains unpublished.

## Publish vendor terms separately

`config/vendor_terms.yml` is the blank repository-owned agreement template. Initially `published: false` and `agreement: ''`. Populate approved agreement content, review the terms page, and explicitly set `published: true` in a separate content change. Both publication and nonempty content are required for new acceptance, including forged POSTs. Existing acceptance timestamps remain intact. Never use the test-only agreement as production terms.

## Update existing approval templates after deployment

Invoice/payment/W9 notices use the vendor's designated email. Secure-request rows retain recipient snapshots and delivery history. The updated approval seeds populate defaults only when creating a missing locale record; existing records and administrator-edited content are preserved. Reseeding does not correct an existing template.

Before mail jobs or public access resume, the administrator responsible for communications must approve and manually edit the existing `vendor_notifications_w9_approved` records for **both `en` and `es`** under **Admin → Communications → Email Templates** (`/admin/email_templates`). Preserve each template's customized greeting, footer, support details, supported placeholders and enabled state. Replace wording that says W9 approval fully activates or authorizes the account. Keep `%<status_box_text>s`; its runtime title and body now distinguish approval from authorization. Suggested replacement paragraphs:

- English: “W9 approval and vendor authorization are separate steps. Before you can process vouchers, your vendor account must also be authorized by the program. Check your vendor dashboard for any remaining onboarding steps.”
- Spanish: “La aprobación del W9 y la autorización del proveedor son pasos separados. Antes de procesar vales, el programa también debe autorizar su cuenta de proveedor. Consulte su panel para ver los pasos pendientes.”

Use the editor's preview and designated test-send for each locale, verify that no activation claim remains and that the status body matches the vendor's actual blocker, then resume mail only after the remaining cutover checks. Obtain the content owner's approval for customized copy; do not overwrite it with a bulk seed or task.

## Failure and recovery

Prefer a forward fix while access, uploads and jobs remain paused. If a task fails, retain its completed cursors and old-key checkpoints, correct the cause and resume the same task with the same cutover timestamp. Storage access must stay restricted until old-key deletion and cache invalidation are verified; an old signed service URL can still work while its old object exists.

Do not roll back to a pre-protection release or run these migrations down after encrypted writes or W9 protection begin. Older code can expose unconverted plaintext TINs in populated forms, invoices or logs, write replacement IDs without encryption, and cannot correctly read the new ciphertext column. It also restores generic Active Storage document routes: old blob references retain their blob IDs, so key rotation alone does not prevent older Rails controllers from resolving them to the replacement key. Older cleanup/purge code can also remove retained review evidence.

An application rollback is acceptable only to a reviewed, compatible protected release that preserves the encryption owner and keys, blank TIN edits/redaction, authenticated W9 streaming/generic-route gate, retention rules and additive schema. Keep web and jobs paused until that release passes the same verification. A Heroku rollback creates a release phase; check its migration behavior rather than assuming that only code changes.

If database or object recovery is necessary, follow [backup and recovery](backup_and_recovery.md#restore-on-heroku) with all access/writers/jobs paused and outbound providers isolated. Restore a matching database, corresponding storage-object snapshot and original encryption/signing credentials into a restricted destination running compatible protected code. Verify database blob keys match restored object keys, decrypt existing records without printing personal values, and review pending jobs/deliveries before resuming. A pre-cutover backup restores the old URL risk and possible plaintext values; rerun this protection/encryption cutover and cache invalidation before opening it. Restoring the database alone after key rotation can point records at deleted objects. Already downloaded copies cannot be recalled.
