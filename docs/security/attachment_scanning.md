# Attachment scanning

Uploaded documents stay private and unavailable until AttachmentScanner returns `ok` for the stored file's SHA-256 and size. A warning, infection, failed scan, missing result, or provider outage does not release the file. A replacement upload gets its own scan.

Development or staging files without a scan record are unavailable too. Upload them again; do not mark them clean or backfill clean results.

Admin document views show **Virus scan** beside a result badge: Passed, Pending, Blocked, Failed, or Not scanned. The result belongs to the displayed file, including the original file in a W-9 review. It is separate from staff approval of the proof, certification, or W-9.

Scanning uses private server uploads. The scanner receives file bytes with a random filename, not the original filename or an application download link. Scan jobs submit and poll in the background. A shared database budget spaces operations at least twenty-one seconds apart across workers. This leaves room for up to three HTTP requests per operation, including redirects, under the provider's default limit of ten requests per minute. A rate-limit response schedules a bounded retry. Secure upload forms keep their policy-controlled expiry; downloading and scanning a document do not shorten that lifetime.

## Configuration

Heroku supplies `ATTACHMENT_SCANNER_URL` and `ATTACHMENT_SCANNER_API_TOKEN` when the add-on is provisioned. Production requires both at startup, except while compiling assets. The URL must be an AttachmentScanner HTTPS origin. Credentials are not written into jobs or logs. Development and tests can boot without the add-on; an unavailable real scanner cannot mark a file clean.

The integration uses the existing `http` gem and the versioned `/v1.0/scans` API. It polls authenticated results rather than trusting a public callback. It follows at most two method-preserving redirects to trusted provider HTTPS hosts on the same API path. Other redirects fail closed.

The provider retains scan metadata, including hashes and results, after discarding file bytes. Confirm the selected region, scan-engine package and metadata retention with the provider before sending personal documents. A short-lived S3 URL is not sent to the provider. See the [API reference](https://www.attachmentscanner.com/docs/api.html), [Heroku setup](https://devcenter.heroku.com/articles/attachment-scanner), and [provider security policy](https://www.attachmentscanner.com/security).

Upload allocation is capped at thirty files per account per day, ten per secure form per day, 150 globally per day, and fifty pending scans. Provider-generated DocuSeal documents use the global and pending limits. These are application allocation limits; submission retries can still consume additional paid scans.

## Failures and recovery

The worker claims a five-minute lease before contacting the provider and checks that lease when saving a result. A minute-by-minute recovery job resumes due work and expired leases. Uploads that are still unresolved after an hour fail closed. Submission retries are limited to three attempts; result polling is also bounded. Failed credentials, an expired subscription and malformed responses need operator attention.

A lost submission response can mean that a scan was accepted but its ID never reached Rails. A bounded retry may cause another billable scan. The application does not promise exactly-once provider billing.

If a signed DocuSeal PDF is blocked or its scan fails, it stays unavailable. The application records `document_signing_attachment_failed` and creates an in-app notice for admins, without sending email or marking the document signed. Recovery retries any unfinished failure reporting. A result from an older signing request does not change or alert on a newer request. A repeated webhook received while its file is still uploading gets a retryable response without a false failure event.

An overnight cleanup removes terminal scan records and private snapshots that have remained unattached for seven days. It keeps attached documents and their scan state. Files still awaiting a result remain blocked; cleanup does not make them available.

## Monitoring and operator actions

Rails emits structured `document_scan.completed`, `document_scan.backlog` and `document_scan.allocation_limited` events to application logs. They contain scan IDs, state, fixed error codes and counts, without document names, contents, API credentials or form tokens. A backlog event means a pending scan is more than fifteen minutes old.

Configure the production log monitor to alert on `unauthorized` or `subscription_expired`, repeated `transport_error` failures, and a backlog that persists for fifteen minutes. Monitor worker and recurring-scheduler health as well: a stopped scheduler cannot report its own backlog. Watch allocation-limit events and the provider dashboard for unexpected scan volume. The application emits the signals; a log drain and alert destinations must be configured in the hosting environment.

When scans stop completing:

1. Check that the worker and recurring scheduler are running. Confirm provider availability, credentials and remaining quota in the add-on dashboard without copying credentials into tickets or logs.
2. Fix the provider or worker issue. Recovery resumes pending work whose lease expired. Clean files already attached remain available.
3. For a terminal failed upload, ask the uploader to submit the file again. For a failed DocuSeal intake, send a new signing request. An interrupted snapshot is not acknowledged as a successful intake. For a warning or infection, request a replacement document. Do not change the scan to clean manually.

## First-release checks

Before enabling document intake on the deployed application:

- Re-upload any documents you intend to keep that have no scan record, using the normal upload forms after deployment. This includes sample documents loaded by development seeds: seeding alone does not scan them. Keep user accounts and credentials; a database reset is not part of this cutover. There is no automatic rescan or clean-result backfill, and the old files remain blocked.
- Confirm the provisioned plan, scanning engines, region, API limit and quota behavior.
- Submit a synthetic clean document and confirm it becomes available. Test EICAR in a supported document format, or through the provider API if intake rejects its type. Check the provider's verdict and confirm the infected file stays blocked; a type rejection does not test the antivirus engine.
- Exercise a worker restart and provider outage. Confirm pending files stay blocked and recovery resumes safely.
- Confirm logs and provider scan history omit original document names and application tokens, and that backlog and credential alerts reach an operator.

These live provider checks supplement automated tests. They do not require real applicant, medical or tax documents.
