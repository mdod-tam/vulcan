# Vendor tax records and onboarding deployment

This release has two schema migrations. It keeps Active Storage as the document store and retains reviewed W9s in the vendor's internal `w9_archive`. W9 approval and program authorization remain separate decisions.

## Deployment order

1. Back up the database, storage objects, and encryption credentials. Record the cutover timestamp in UTC. Put the application behind maintenance access that also blocks storage retrieval, and pause uploads, application writers, invoice generation, attachment purge jobs, and unattached-upload cleanup. Keep maintenance access in place until key rotation and cache invalidation have completed.
2. Apply `20261009120000_protect_business_tax_ids` and `20261009120100_bind_w9_reviews_to_documents`. The first widens `users.business_tax_id` to text and removes its unused nonunique index. The second adds a restrictive blob foreign key and unique vendor/document index, and removes the implicit approval default. Historical review references stay NULL when the document is unknown; this release does not infer them from today's W9.
3. Verify stable `active_record_encryption.primary_key`, `deterministic_key`, and `key_derivation_salt` in credentials on every application instance and in the restore procedure. Run `RAILS_ENV=production bin/rails vendor_tax_records:check_keys` from the release image. This check reports configuration, never key values. Production startup now refuses absent or incomplete keys. The Docker asset build may use temporary keys only for the exact `SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile` invocation; that exception does not permit application, job, database, or combined-task startup without stable keys. Do not replace existing keys when adding TIN encryption; confirm a previously encrypted user can still be read by the release image. Preserve `secret_key_base` for existing signed references and sessions.
4. Deploy the application while public access remains paused. New model writes encrypt TINs non-deterministically, and encrypted audit copies use the existing `Event#change_values` owner. Plaintext reads remain supported for the resumable transition. The new W9 uploader binds retry references to a vendor, while authorized downloads stream through the application with private, non-cacheable responses. Ordinary blob, proxy, representation, preview, variant, and disk routes deny protected W9s.
5. Run the resumable storage and TIN tasks below. Purge previously cached W9 responses from any reverse proxy/CDN and remove public storage permissions. Verify storage-key deletion has succeeded, including old preview and variant objects. Resume access and jobs only after verification.

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

Use the actual recorded timestamp, not the example. The task prints `AFTER_VENDOR_ID` and `AFTER_STAGED_BLOB_ID`. Resume with the same timestamp and the last completed cursors. It follows vendor → secure-request → blob lock order, protects current/retained/known-reviewed files and their derivatives, and copies each object to a new key without changing its blob ID or creation time. An old-key checkpoint commits before deletion; on failure, the next run completes deletion without rotating again. Keep storage access paused on failure, because a cloud service URL can continue working while its old object remains. Application disk routes also recognize old-key checkpoints and deny them.

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

Invoice/payment/W9 notices use the vendor's designated email. Secure-request rows retain their recipient snapshots and delivery history. The updated English/Spanish approval seeds explain that W9 approval does not authorize redemption; inspect any existing customized approval templates, since seeds do not overwrite administrator-edited stored content.
