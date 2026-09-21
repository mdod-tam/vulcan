# Testing and Debugging

Minitest for Ruby, Jest for JavaScript, Capybara with Cuprite for the browser.

What follows is the repository-specific part: shared setup that changes behavior, helpers that are easy to pick wrong, and the switches worth knowing when something fails.

```bash
bin/rails test test/models/user_contact_predicates_test.rb
bin/rails test test/models/user_contact_predicates_test.rb -n /real_email/
SYSTEM_TEST_WORKERS=1 bin/rails test test/system/registrations_test.rb
yarn test test/javascript/controllers/upload_controller_test.js --runInBand
```

CI runs the full system suite. Locally, browser runs share the test database, so two suites at once will interfere, and browser tests exercise built assets — `yarn build` and `yarn build:css` after frontend changes.

## Shared setup that changes behavior

[`test_helper.rb`](../../test/test_helper.rb) loads factories and support helpers, seeds shared data, configures mail and job adapters, and resets request state between tests. Ordinary tests run in transactions; [`ApplicationSystemTestCase`](../../test/application_system_test_case.rb) truncates instead, which is why adding a cleaning strategy to an individual test causes trouble rather than fixing it.

The [initialization tasks](../infrastructure/setup_and_maintenance.md#baseline-seeds) are for setting up an environment. Tests should use the shared seed and scenario-specific policy records/helpers. Policy defaults are declared separately in `db/seeds.rb#create_policies` and `lib/tasks/seed_policies.rake`; update both when an initialization default changes.

Four pieces of that setup surprise people:

- **The waiting-period validation is disabled globally** (`Application.skip_wait_period_validation = true`). Testing that rule means enabling it deliberately and restoring the prior value.
- **[Paper application context](../../test/support/paper_application_context_helpers.rb) changes validation.** It belongs to paper-intake scenarios; used in a portal test it can hide the defect under test.
- **Income eligibility needs [`setup_fpl_policies`](../../test/support/fpl_policy_helpers.rb)** — thresholds come from policy rows, not constants.
- **Transaction races need [`ConcurrencyTestHelper`](../../test/support/concurrency_test_helper.rb)**, because a second database connection cannot see uncommitted setup data.

Factories are in [users](../../test/factories/users.rb) and [applications](../../test/factories/applications.rb); traits like `:with_income_proof` attach real fixture files, which matters when the test covers upload, download, rendering, or validation rather than mere attachment presence.

## Sign-in helpers are per base class

Choosing by directory rather than by base class is the usual cause of a session that does not stick.

| Base class | Helper |
| --- | --- |
| `ActionController::TestCase` | `sign_in_for_controller_test(user)` |
| `ActionDispatch::IntegrationTest` | `sign_in_for_integration_test(user)` |
| Model or service needing an actor | `sign_in_for_unit_test(user)` |
| `ApplicationSystemTestCase` | `system_test_sign_in(user)` |

The [request helpers](../../test/support/authentication_test_helper.rb) arrange cookies, headers, and `Current.user` — setting `Current.user` alone does not create a browser session — and the [browser helper](../../test/support/system_test_authentication.rb) manages its own. All of them bypass MFA enrollment by default; `bypass_mfa_enrollment: false` turns that off for the controller and integration helpers. Tests of sign-in, recovery, or MFA itself have to drive the real flow, since the helpers skip the thing under test.

## Browser tests

[`ApplicationSystemTestCase`](../../test/application_system_test_case.rb) holds driver configuration and cleanup. Locators favor labels, button text, and scoped sections, falling back to a stable ID or `data-testid` where no semantic locator is unambiguous.

The [browser helpers](../../test/support/system_test_helpers.rb) cover the recurring waits — `wait_for_turbo`, `wait_for_stimulus_controller`, modal open and close. A page going idle is not proof the operation succeeded, so the wait goes before the assertion, not instead of it. After a Turbo replacement, an element captured earlier is detached.

`js_errors: true` fails browser tests on uncaught errors and rejected promises; a small hook rethrows Stimulus-reported errors. Runtime errors and missing declared controllers invalidate screenshot sidecars.

Screenshots taken in system tests write a JSON sidecar alongside the image recording whether the capture is usable — a blank page or an `about:blank` URL is flagged with its reasons rather than being saved as apparent evidence.

## When something fails

Reproduce the single file or test name first; for order-dependent failures, keep the reported seed and rerun the group with `--seed`. `log/test.log` and, for browser failures, the screenshot and saved HTML under `tmp/capybara/` show what the test actually reached — often a different page than assumed. Setup is worth checking before timeouts: the right user, the required policy rows, current assets, the expected frame or modal.

| Switch | Effect |
| --- | --- |
| `bin/test-quiet <file>` | Reduced logging (the default). |
| `bin/test-verbose <file>` | Verbose output. |
| `bin/run-test <file>` | Authentication diagnostics plus failure screenshot/HTML settings. |
| `HEADLESS=false` | Show the Cuprite browser. |
| `SLOWMO=0.5` | Slow Cuprite actions down. |
| `DEBUG_AUTH=true` | Authentication helper diagnostics. |
| `SYSTEM_TEST_WORKERS=1` | One browser worker, for isolating interference. |

```bash
HEADLESS=false SLOWMO=0.5 SYSTEM_TEST_WORKERS=1 bin/run-test test/system/registrations_test.rb
```

`debugger` works in the failing path when the focused test runs in a terminal.

## Where tests live

`test/models` for model rules, `test/services` for workflow state and side effects, `test/controllers` and `test/integration` for access and responses, `test/system` for tasks a person completes in a browser, `test/javascript` for Stimulus controllers. Assertions target the observable result — saved state, response, audit event, queued delivery, visible behavior — and a regression test carries the condition that caused it, including what the unsuccessful attempt left behind.

Related: [proof review](../features/proof_review_process_guide.md) · [service architecture](service_architecture.md) · [test support helpers](../../test/support)
