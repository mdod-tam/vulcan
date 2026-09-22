# JavaScript Architecture

Rails renders every page and the state it starts from.

Stimulus controllers add per-element behavior.

Turbo handles navigation and partial updates.

The server re-decides anything the browser decided.

## Conventions

- **Registration is manual.** [`controllers/index.js`](../../app/javascript/controllers/index.js) imports and registers each controller explicitly; [`controllers/application.js`](../../app/javascript/controllers/application.js) registers nothing on purpose. An unregistered controller is inert, with no error.
- **The identifier is the registered name, not the path.** `admin-user-search` lives at `admin/user_search_controller.js`.
- **Assets are built, not served from source.** [esbuild](../../esbuild.config.js) bundles `app/javascript/application.js` into `app/assets/builds` (`yarn build`); Tailwind is `yarn build:css`.
- **Views own URLs and copy.** Controllers read them from values rather than constructing paths, which is why templates pass `:id` placeholder routes for URLs a controller will need after a record exists.
- **Both attachment syntaxes are in use** — literal `data-controller` attributes and ERB `data:` hashes — so a grep for one finds roughly half the call sites.

## Autosave, as a representative interaction

The constituent application form autosaves on blur: [`autosave_controller.js`](../../app/javascript/controllers/forms/autosave_controller.js) sends one `field_name`/`field_value` pair per save to `ConstituentPortal::ApplicationsController#autosave_field`, which delegates to [`Applications::AutosaveService`](../../app/services/applications/autosave_service.rb). File inputs and `data-no-autosave` fields are excluded; uploads go through direct upload instead.

Two behaviors are not visible from the controller alone:

- **The first save may create the draft.** When the response carries an `applicationId` the form lacked, the controller rewrites the form `action`, switches its own URL to the member route, and injects `_method=patch`. The two `:id` placeholder values in [`applications/new.html.erb`](../../app/views/constituent_portal/applications/new.html.erb) exist for that substitution.
- **Validation comes back per field**, rendered next to the offending input, with the outcome also announced through an `aria-live="polite"` status region that clears after three seconds.

## rails_request

[`services/rails_request.js`](../../app/javascript/services/rails_request.js) wraps `@rails/request.js`. `perform()` has three outcomes, not two: `{ success: true, data, response }`, `{ success: false, aborted: true }` on cancellation, and a thrown `RequestError` carrying `status` and `data` for a non-OK response.

Requests are tracked by `key`, and reusing an in-flight key cancels the earlier request — autosave uses a single key per form, so rapid edits collapse to the last one. Cancellation is client-side only; the server may have already committed, so ordering-sensitive controllers still need their own staleness check.

`tryShowFlash` is a no-op that returns `false` — a leftover from a removed toast library. Failed requests need their own visible feedback, via the [flash container](../../app/views/shared/_flash.html.erb) or inline status text.

`BaseFormController#collectFormData` ([base/form_controller.js](../../app/javascript/controllers/base/form_controller.js)) flattens `FormData` into literal keys: `constituent[email]` stays that string rather than nesting. Names ending in `[]` become arrays under the unbracketed name.

Server-rendered HTML goes through Turbo frames and streams. Authentication and a few lookups still call `fetch` directly and keep their own response contracts.

## Submit gating

| Controller | Responsibility |
| --- | --- |
| [final-submit-gate](../../app/javascript/controllers/forms/final_submit_gate_controller.js) | Final submit button state from required fields, radio and checkbox groups, income state, and a server-supplied block |
| [income-validation](../../app/javascript/controllers/forms/income_validation_controller.js) | Displayed threshold, and whether entered income exceeds it |
| [paper-application](../../app/javascript/controllers/forms/paper_application_controller.js) | Staff intake readiness, applicant verification, proof choices, upload progress |
| [adult-picker](../../app/javascript/controllers/users/adult_picker_controller.js) / [guardian-picker](../../app/javascript/controllers/users/guardian_picker_controller.js) | Existing-person selection plus the eligibility and relationship context the server returns |
| [applicant-type](../../app/javascript/controllers/users/applicant_type_controller.js) / [dependent-fields](../../app/javascript/controllers/forms/dependent_fields_controller.js) | Self/dependent branch switching and dependent contact choices |
| [upload](../../app/javascript/controllers/ui/upload_controller.js) | Direct upload, progress, replacement, removal |

These coordinate by event, not by reference: `income-validation` dispatches `income-validation:validated` with `{ exceedsThreshold, income, threshold, householdSize }` and the gate recomputes.

Constraints that are easy to break:

- `@submission_blocked_message` renders as `data-final-submit-gate-blocked-message`; any non-empty value disables final submit regardless of field completeness, and an empty value blocks nothing. The authoritative check is Rails' own, under lock at save time.
- The gate recomputes on every `input`/`change`, so an externally set `disabled` does not survive. New conditions belong in the gate.
- Blank, unchecked, disabled, and absent are four distinct submissions — browsers drop unchecked boxes and disabled controls entirely, hence the hidden `"0"` companions. [Paper intake retry](paper_application_architecture.md#retry-restoration) depends on the distinction.
- Secure-request recipient forms are the only conditional-channel case: unchecking a recipient clears and disables its channel, re-checking restores the server's email/letter default, and SMS stays explicit.

## Paper identity review and uploads

The paper form uses Rails automatic direct uploads for its four documents. Normal `POST /admin/paper_applications` returns a server-rendered identity review or validation form with retained signed IDs and filenames. Current pages make no identity preflight or second eligibility fetch. The legacy preview route only resumes submission from older open forms; see [deployment and recovery](paper_application_architecture.md#deployment-and-recovery).

Review choices use normal submit buttons, a rationale, and a short-lived `identity_review_receipt`. Rails locks and recomputes the facts at the write; changed or expired facts require a fresh review. Guardian quick-create posts through `admin-user-search`, receiving an HTML review fragment on refusal or the saved/selected guardian as JSON on success.

[`document-proof-handler`](../../app/javascript/controllers/users/document_proof_handler_controller.js) displays saved paper uploads, replaces a reference only after a successful upload, and clears it on explicit removal or rejection. Failed or canceled replacements retain the prior upload. Proof actions are locked while an upload is pending; Rails owns the form-wide upload lifecycle. Native file inputs cannot be repopulated.

## Password visibility

[`PasswordFieldHelper#password_visibility_data`](../../app/helpers/password_field_helper.rb) wires the [`visibility` controller](../../app/javascript/controllers/ui/visibility_controller.js) and supplies translated labels; `password_field_with_toggle` generates the full field. Revealed passwords re-hide after five seconds (`timeout: 10000` for ten), and the toggle maintains `aria-pressed`, its label, and live status text.

Form length hints should track [the server validation](../../app/models/concerns/user_authentication.rb), currently eight characters.

## Charts

[`chart_controller.js`](../../app/javascript/controllers/charts/chart_controller.js) imports Chart.js and registers only bar-chart components. It remains part of the single application bundle. Views provide a canvas inside a relatively positioned container with a fixed height, plus stable accessible labels and text descriptions.

`connect()` constructs one responsive chart from the primary and optional comparison data. `disconnect()` destroys it. Chart.js handles container resizing and device-pixel-ratio changes; the controller does not measure, replace, defer, or poll canvases. Horizontal bars use `indexAxis: "y"`. Tooltips and normal Chart.js interactions remain enabled.

The vendor chart is constructed while hidden. [`chart-toggle`](../../app/javascript/controllers/charts/toggle_controller.js) only toggles its region and button state; Chart.js resizes the canvas when revealed. Reports retain the numeric cards and consolidated comparisons without the six duplicate compact charts.

Production builds are minified and omit source maps; development builds retain them. Production also excludes the unused Turbo and Stimulus gem assets, including their source maps, because esbuild bundles these libraries. The shared debounce utility provides trailing calls and cancellation for controller teardown.

## Tests

Jest on jsdom ([jest.config.js](../../jest.config.js)), with `@rails/request.js` mapped to a [mock](../../test/javascript/mocks/rails_request.js) and `controllers/*` resolving into `app/javascript/controllers`.

```bash
yarn test test/javascript/controllers/final_submit_gate_controller_test.js
```

[Request-service tests](../../test/javascript/services/rails_request_service_test.js) cover the three `perform()` outcomes; [upload](../../test/javascript/controllers/upload_controller_test.js) and [paper-form](../../test/javascript/controllers/paper_application_controller_test.js) tests cover the more stateful controllers.

Native form submission, focus, layout, and Turbo frame replacement are not real under jsdom — those belong in system tests ([testing and debugging](testing_and_debugging_guide.md)).
