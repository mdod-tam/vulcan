# Content Security Policy

[The initializer](../../config/initializers/content_security_policy.rb) configures an enforced Content Security Policy (CSP): browser rules for permitted scripts, styles, connections, and other resources. It sends **Content-Security-Policy** on application responses. Disallowed resources are blocked and can produce a diagnostic report.

There is no environment switch to report-only mode. Changing enforcement or policy directives requires editing the initializer and deploying that code. First-release verification therefore exercises the enforcing policy before opening the environment to users.

The application policy starts with its own origin, disables objects, restricts base URLs, form submissions, and frame ancestors, and supplies a fresh nonce for each request's scripts and styles. Layouts expose that nonce through `csp_meta_tag`. Static browser styles live in the CSS asset: Turbo parses incoming HTML under the current document's policy, so an incoming response's nonce does not authorize a new inline stylesheet there. Any new inline resource needs a real Turbo-navigation check as well as a full-page load check. The application policy does not allow `unsafe-inline`; filter submission uses Stimulus actions. Blob/data sources are limited to the resource categories that need them.

Secure-document action confirmations use Turbo form attributes, with 303 redirects after completed POST actions. Voucher usage uses a native progress value and static styles. Browser controls must keep behavior in those external/platform owners rather than adding inline event handlers or style attributes.

Browser uploads and scan-status checks use the application's own origin, so `connect-src` allows only `self`. Rails sends files to private storage and the [antivirus service](attachment_scanning.md). Those server requests do not need browser CSP sources or bucket CORS. The [storage initializer](../../config/initializers/active_storage.rb) validates selected bucket/region settings at startup; see [storage configuration](../infrastructure/active_storage_s3_setup.md).

## HTML email previews

Saved, draft, and test-email HTML previews share a [sandboxed iframe](../../app/views/admin/email_templates/_html_preview.html.erb) and an authenticated [preview document](../../app/controllers/admin/email_templates_controller.rb). The document has its own default-deny CSP and sandbox response header. Forms, top-level navigation, and remote resources are blocked; data images and inline email styles are allowed inside this isolated document. The parent application's policy stays strict. The response is private/no-store and sends no referrer.

Saved and test-email GET documents block scripts entirely. An unsaved HTML draft response permits only a fixed, server-authored result reporter with that response's script nonce. Its sandbox allows scripts while retaining an opaque origin, without `allow-same-origin`. Editable HTML receives no script nonce, external scripts remain blocked, and script attributes are disabled. The reporter sends a fixed message type and success/failure boolean to the parent. The [parent controller](../../app/javascript/controllers/admin/email_preview_controller.js) checks the exact iframe window, opaque origin, message type, and boolean before announcing a fixed error string. It does not insert message HTML or draft error text into the parent.

The reporter runs in the routed draft response. Its `window.location.origin` is the application URL's origin and explicitly targets the parent; the sandbox's `window.origin` and received message origin are `null`. An initial rendering error instead uses an alert-only `about:srcdoc` document, whose URL origin is `null`. That document has no reporter: the parent error is already rendered, and a retry navigates the named iframe to the routed draft response.

Draft preview submits the editor's validated, unsaved values into that iframe. It uses the same template renderer and sample-data owner as saved preview, without changing stored templates or delivered email markup. Text previews remain escaped application content. How a preview looks in a browser doesn't tell you how a recipient's email client will render the message.

## Reports and logging

Browsers POST diagnostics to the public `/csp_reports` collector. It has no application sign-in, MFA, session-refresh, or audit-actor callbacks and is exempt from CSRF checks. Treat a report as untrusted diagnostic input. It doesn't point to a particular user or confirm an attack.

[Middleware before the Rails request logger](../../lib/security/csp_report_filter.rb) filters request parameters and validates the body before Rails can log it. It accepts `application/csp-report`, `application/reports+json`, and `application/json`, rejects query strings, bounds the body at **16 KiB**, and limits JSON nesting to 20. Malformed JSON, oversized bodies, and unsupported content types are rejected there, including requests with format suffixes.

[The report projection](../../app/services/csp_violation_report.rb) accepts the legacy `csp-report` shape and Reporting API `csp-violation` batches of at most **10 reports**. Diagnostics keep allowlisted directive/disposition categories, URL origins, and bounded numeric line/column positions. URL paths, queries, fragments, user information, script samples, and arbitrary extra fields are excluded. Non-network sources are reduced to categories such as `inline` or `data`.

[The controller](../../app/controllers/csp_reports_controller.rb) limits processing to **30 requests per minute per keyed IP digest**, using the configured cache store. Accepted reports produce warning logs and a no-store 204 response. The endpoint creates no users, sessions, or audit events. These application controls do not configure upstream logging or prove centralized retention and alerting.

## Verify in the deployment environment

Before opening access, verify the enforcing response header and exercise sign-in/MFA, Turbo navigation, Stimulus filters, charts, isolated template previews, and document uploads with the target browser and application host. Review real-browser diagnostics and correct the owning resource or source setting when necessary. Passing header and collector tests doesn't mean the deployed policy works in real browsers.

Keep the collector bounded and redact diagnostics when adjusting policy sources. Deployment TLS, proxy headers, caching, and log retention need their own verification.

[Collector/header tests](../../test/controllers/csp_reports_controller_test.rb) and [projection tests](../../test/services/csp_violation_report_test.rb) cover the automated side. They don't show that anyone has tried a deployed configuration.
