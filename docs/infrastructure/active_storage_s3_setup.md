# Active Storage and S3

Active Storage stores uploaded proofs, disability certifications, vendor W-9s, and public product-guidance PDFs. Uploaded files stay unavailable until their antivirus scan passes.

Tests and development default to disk storage. Development can opt into S3; other environments use S3.

One S3 configuration serves both a Bucketeer add-on and direct AWS credentials.

## Which service is used

[`config/initializers/storage.rb`](../../config/initializers/storage.rb) decides in a `to_prepare` block, which runs after the environment files and therefore wins over the `config.active_storage.service` lines in them:

| Environment | Service | Where files go |
| --- | --- | --- |
| test | `:test` | `tmp/storage` |
| development | `:local`, or `:s3` when `USE_S3=true` | `storage/`, or the bucket when `USE_S3=true` |
| everything else | `:s3` | the bucket |

## Credentials

The `s3` entry in [`config/storage.yml`](../../config/storage.yml) reads direct credentials first and falls back to Bucketeer's, so the same deployment works either way and switching providers is an environment-variable change rather than a code change:

| Setting | Direct | Bucketeer fallback | Default |
| --- | --- | --- | --- |
| Access key | `S3_ACCESS_KEY_ID` | `BUCKETEER_AWS_ACCESS_KEY_ID` | — |
| Secret | `S3_SECRET_ACCESS_KEY` | `BUCKETEER_AWS_SECRET_ACCESS_KEY` | — |
| Region | `S3_REGION` | `BUCKETEER_AWS_REGION` | `us-east-1` |
| Bucket | `S3_BUCKET` | `BUCKETEER_BUCKET_NAME` | — |

Bucket names are serialized as strings in the YAML configuration, including numeric names and names such as `off`; YAML must not reinterpret them as numbers or booleans. The storage initializer accepts ordinary bucket names using [AWS naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html); access-point aliases and other specialized bucket types are outside this storage contract.

On Heroku, a Bucketeer add-on supplies its four variables; direct S3 uses the `S3_*` settings above. Verify private bucket access before accepting uploads.

`storage.yml` also carries commented templates for GCS, Azure, and a mirror service; using one means adding its case to the initializer as well.

## Local development against S3

`.env` is not loaded. `.env.example` exists, but there is no `dotenv-rails` in the Gemfile — the `dotenv` in `Gemfile.lock` arrives only as a Kamal dependency — and [`bin/dev`](../../bin/dev) starts foreman with `--env /dev/null`, which disables foreman's own `.env` handling. Export the variables or put them on the command line:

```bash
USE_S3=true S3_BUCKET=… S3_ACCESS_KEY_ID=… S3_SECRET_ACCESS_KEY=… bin/dev
```

The storage initializer rejects selected blank or malformed bucket/region settings at startup, naming the setting without printing its value. It supports commercial AWS and GovCloud endpoints. Missing buckets or credentials for a selected S3 service remain SDK errors; without supplied credentials the SDK may try EC2 instance-profile discovery. Leave unused variables unset rather than supplying empty placeholders.

## Uploads and scanning

Paper intake, portal proof submission, secure upload forms, vendor W-9s, certifications, and product-resource uploads send files to Rails. Rails validates and stores a private snapshot, then sends its bytes to AttachmentScanner. Only a matching clean result permits attachment, preview, download, or processing. The browser checks scan status on the application origin and can retain a clean upload while correcting other form fields. See [attachment scanning](../security/attachment_scanning.md) for configuration and recovery.

The browser does not upload to S3, so these forms do not require bucket CORS or S3 sources in the browser CSP. The generic and vendor direct-upload allocation endpoints are not mounted.

## Document retrieval

Proof, certification, and tax documents can contain personal information, so keep the bucket private. [Application-owned storage routes](../../config/routes/active_storage.rb) resolve the application's blob and representation helpers to authenticated proxy downloads that check the document's audience on every retrieval. Generated download links expire after **15 minutes**. If a link expires, refresh the page with the download link. Secure upload forms keep their configured policy lifetime; this limit does not shorten them. Retained upload references and dedicated W9 record routes have separate lifetimes. An already downloaded copy cannot be recalled. A signed blob reference identifies a document; it does not grant permission to read it. Proofs require a signed-in administrator, the applicant when no guardian manages the application, or its managing guardian. Primary and additional medical certifications require an administrator. The full application sign-in, required MFA enrollment, password-change, and session-expiry gates apply. Downloads stream through Rails with private, non-cacheable responses. Redirect and disk download routes are not mounted.

**W9s retain their dedicated authenticated streaming route**, with separate current, staged and retained-document rules. Generic blob, representation and disk downloads refuse protected W9s. Print queue letters leave only through the administrator POST release action and its delivery checks. Unattached uploads, unknown attachment slots, direct generated-blob links and mixed public/private attachments have no generic download audience. A representation checks its original document before processing. Public resubmission links permit submission only, and the blank medical certification form stays public.

Keep application-generated storage-service URLs out of sensitive-document views and APIs. Such URLs bypass application permission checks until their storage signature expires. A downloaded copy cannot be recalled. See [vendor onboarding setup](vendor_onboarding_setup.md) for first-release W9 verification.

## Public product guidance PDFs

`ProductResource#document` holds public, product-specific program guidance rather than a constituent/session upload. Admin product management explains that saving publishes the resource and prohibits personal, application, or session information. Guidance requires exactly one safe absolute HTTP(S) URL or PDF, a title, and a supported authored language. PDFs have a 10 MB inclusive limit, must identify as PDF from content, and require a clean antivirus result. Use searchable/tagged PDFs, and captions/transcripts for externally hosted videos. The application does not convert PDFs or certify accessibility.

These PDFs use the same application-owned proxy route with attachment disposition and the same 15-minute generated URL expiry. If a link expires, refresh the page with the download link. Only blobs attached exclusively to `ProductResource#document` have this explicit public audience; they require no sign-in and carry no personalized application/device relationship. A W9 protection marker or an additional attachment of another kind prevents public access. Devices and shared training reports authorize their relationships separately before linking to the same public guidance. Manufacturer documentation remains separate catalog metadata.

The manual-upload gate validates size, inspects content, checks blob reuse, and requires a clean antivirus result. Resource publication, attachment change, and structural audit share a transaction. A failed replacement/source switch retains the prior saved resource and PDF; a clean staged upload can be retained for a corrected submission. Replaced content is purged after successful commit. Resource audits omit URLs/file bodies/signed references, and request/SQL filters hide URL and upload values.

## Verify upload and retrieval

Inspect the selected service in the target environment without printing credentials:

```bash
bin/rails runner 'puts Rails.application.config.active_storage.service'
heroku run --app your-app-name "bin/rails runner 'puts Rails.application.config.active_storage.service'"
```

Complete these checks before first release:

1. Compare the effective bucket and region selected by `config/storage.yml` with the target deployment settings. Do not print the access key, secret, or the entire storage configuration. A defined but blank `S3_BUCKET` or `S3_REGION` overrides its Bucketeer counterpart and fails startup. Unset unused direct variables so storage selects the intended Bucketeer fallback.
2. Resolve missing settings before accepting uploads, and confirm the deployment refuses malformed bucket/region values at startup. Commercial AWS and GovCloud are supported; other partitions fail with a setting-name error. Confirm `connect-src` allows only the application origin.
3. Using a verification record and a nonsensitive PDF, upload through a portal proof form or vendor W-9 form. Confirm the file stays unavailable while scanning, becomes usable only after a clean result, and is saved in the intended private bucket. Submit the form and open its attachment through the authenticated application route. Complete the [live scanner checks](../security/attachment_scanning.md#first-release-checks) with synthetic files.
4. Reuse the application download URL after logout and from an unrelated account; it must not return private bytes. Confirm authorized responses carry private/no-store headers through the deployment proxy. Verify public product guidance separately against its explicit public audience.

## Backup and recovery

PostgreSQL stores blob/attachment metadata, not file bodies. Back up S3 objects separately and retain their object keys. A replacement bucket may use different credentials and a different region, but the Active Storage service named by existing blob records must reach those objects. Changing the default service does not migrate existing blobs.

For disk storage, preserve the configured storage directory. Verify both an old attachment and a new upload after recovery. Use a separate bucket for restore rehearsals; see the [recovery checklist](backup_and_recovery.md#recovery-checklist).
