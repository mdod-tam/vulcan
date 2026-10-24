# Attachment scanning

Uploaded documents stay private and unavailable until AttachmentScanner returns `ok` for the stored file's SHA-256 and size. A warning, infection, failed scan, missing result, or provider outage does not release the file. A replacement upload gets its own scan.

Files without a scan record are unavailable in every environment. Upload them again; do not mark real uploads clean or backfill clean results. Development seeds and test factories can clear fixed, synthetic repository fixtures through an environment-guarded helper. Those fixtures do not contact the provider or consume upload allocation limits; they are not evidence of a real antivirus scan.

Admin document views show **Virus scan** beside a result badge: Passed, Pending, Blocked, Failed, or Not scanned. The result belongs to the displayed file, including the original file in a W-9 review. It is separate from staff approval of the proof, certification, or W-9.

Scanning uses private server uploads. The scanner receives file bytes with a random filename, not the original filename or an application download link. Scan jobs submit and poll in the background. A shared database budget spaces actual HTTP requests at least seven seconds apart across workers, including redirects, under the provider's default limit of ten requests per minute. A rate-limit response schedules a bounded retry. Secure upload forms keep their policy-controlled expiry; downloading and scanning a document do not shorten that lifetime.

## Configuration

Heroku supplies `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN` when the add-on is provisioned. Production requires both at startup, except while compiling assets. The URL must be an AttachmentScanner HTTPS origin. Credentials are not written into jobs or logs. Development and tests can boot without the add-on; an unavailable real scanner cannot mark a file clean.

The integration uses the existing `http` gem and the versioned `/v1.0/scans` API. It polls authenticated results rather than trusting a public callback. It follows at most two method-preserving redirects to trusted provider HTTPS hosts on the same API path. Other redirects fail closed.

The provider retains scan metadata, including hashes and results, after discarding file bytes. Confirm the selected region, scan-engine package and metadata retention with the provider before sending personal documents. A short-lived S3 URL is not sent to the provider. See the [API reference](https://www.attachmentscanner.com/docs/api.html), [Heroku setup](https://devcenter.heroku.com/articles/attachment-scanner), and [provider security policy](https://www.attachmentscanner.com/security).

Upload allocation is capped at 150 files per rolling day and fifty pending scans. Public accounts share a smaller limit of fifty files per rolling day and ten pending scans; each public account is also limited to thirty files per rolling day and three pending scans, enough to select all three proofs. This leaves room for staff, issued secure forms and DocuSeal when public accounts reach their limit. Each admin can upload sixty files per rolling day with at most ten pending scans. Each secure form allows ten files per rolling day and two pending scans. All intake still shares the hard program limits and the provider's throughput.

`DocumentScanJob` runs on the dedicated `document_scans` queue with one thread. General jobs use a separate worker for `default`, `mailers`, `low`, and `low_priority`, so scanner pacing cannot occupy the mail worker. The default production configuration has two execution threads across two worker processes; increasing `JOB_CONCURRENCY` adds general workers only. Watch dyno memory and database connections after deployment.

Cancel or Remove stops queued work, prevents later provider requests after cancellation is saved, and releases pending capacity. A request already being sent may still be billed. Cancelled uploads still count toward daily allocation limits: staging a file uses storage and validation work even if it never reaches the scanner. These limits bound allocation, not exact paid scan counts; submission retries can consume additional paid scans.

## Failures and recovery

The worker claims a five-minute lease before contacting the provider and checks that lease and cancellation state before each HTTP request and when saving a result. A minute-by-minute recovery job in development and production resumes due work and expired leases. A scan that remains unresolved an hour after its first provider attempt fails closed; waiting in the ready queue does not consume that hour. An unfinished snapshot upload expires after an hour. Submission retries are limited to three attempts; result polling is also bounded. Failed credentials, an expired subscription and malformed responses need operator attention.

A lost submission response can mean that a scan was accepted but its ID never reached Rails. A bounded retry may cause another billable scan. The application does not promise exactly-once provider billing.

If a signed DocuSeal PDF is blocked or its scan fails, it stays unavailable. The application records `document_signing_attachment_failed` and creates an in-app notice for admins, without sending email or marking the document signed. Retries identify the stored signing request by its submission, submitter and request time; a refreshed download URL does not create another scan. A result from an older signing request does not change or alert on a newer request. A repeated webhook received while its file is still uploading gets a retryable response without a false failure event.

Missing or invalid document URLs, refused files and permanent download failures are acknowledged without asking DocuSeal to retry. Temporary download, storage and capacity failures remain retryable. Failure audits are recorded once per request and failure reason. After a scan finishes, certification acceptance has at most three persisted attempts, with recovery for an interrupted worker. Permanent acceptance failures, a missing application or actor, and exhausted retries leave a terminal failure record instead of being queued again each minute. Send a new signing request after a terminal failure.

`CleanupUnattachedUploadsJob` removes files that have remained unattached for seven days and their scan records. It selects unattached files before locking, then rechecks attachment and pending state under the lock. Pending scans, attached documents, and attached scan history remain intact. The database removes metadata before the storage object is deleted, so a racing attachment cannot acquire a file being purged. A storage deletion failure can leave an orphaned object for operator cleanup; it does not leave a usable database reference to missing bytes.

## Monitoring and operator actions

Rails emits structured `document_scan.completed`, `document_scan.backlog`, `document_scan.allocation_limited` and `document_scan.continuation_gave_up` events to application logs. They contain scan IDs, state, error codes or exception class names, and counts, without document names, contents, API credentials or form tokens. A backlog event means a pending scan is more than fifteen minutes old.

Configure the production log monitor to alert on `unauthorized` or `subscription_expired`, repeated `transport_error` failures, `document_scan.continuation_gave_up`, and a backlog that persists for fifteen minutes. Also alert on `document_scan.continuation_audit_actor_missing`, which means the terminal scan record could not be paired with an audit actor. Monitor worker and recurring-scheduler health as well: a stopped scheduler cannot report its own backlog. Watch allocation-limit events and the provider dashboard for unexpected scan volume. The application emits the signals; a log drain and alert destinations must be configured in the hosting environment.

When scans stop completing:

1. Check that the worker and recurring scheduler are running. Confirm provider availability, credentials and remaining quota in the add-on dashboard without copying credentials into tickets or logs.
2. Fix the provider or worker issue. Recovery resumes pending work whose lease expired. Clean files already attached remain available.
3. For a terminal failed upload, ask the uploader to submit the file again. For a failed DocuSeal intake, send a new signing request. An interrupted snapshot is not acknowledged as a successful intake. For a warning or infection, request a replacement document. Do not change the scan to clean manually.

## First-release checks

Before enabling document intake on the deployed application:

- Re-upload any documents you intend to keep that have no scan record, using the normal upload forms after deployment. Trusted development fixture clearances do not verify the deployed scanner. Keep user accounts and credentials; a database reset is not part of this cutover. There is no automatic rescan or clean-result backfill, and old unscanned files remain blocked.
- Confirm the provisioned plan, scanning engines, region, API limit and quota behavior.
- Submit a synthetic clean document and confirm it becomes available. Test EICAR in a supported document format, or through the provider API if intake rejects its type. Check the provider's verdict and confirm the infected file stays blocked; a type rejection does not test the antivirus engine.
- Exercise a worker restart and provider outage. Confirm pending files stay blocked and recovery resumes safely.
- Confirm logs and provider scan history omit original document names and application tokens, and that backlog and credential alerts reach an operator.

These live provider checks supplement automated tests. They do not require real applicant, medical or tax documents.
