# JavaScript Architecture

A concise reference for the Stimulus, Rails request, form-gating, and Chart.js layer used by MAT Vulcan.

---

## High-Level Flow

1. Rails renders pages with Stimulus `data-controller`, `data-*-target`, and `data-*-value` attributes.
2. Stimulus controllers read server-rendered values, attach DOM listeners, and update local UI state.
3. Controllers use custom events for cross-controller state changes.
4. JSON requests use `rails_request` where the response contract matches that service. Some controllers use direct `fetch` for small endpoint-specific lookups or WebAuthn flows.
5. User-visible page feedback comes from Rails flash rendering, usually through `shared/flash`.

---

## Main Entry Points

| Area | Entry Point | Notes |
|------|-------------|-------|
| Bundle | `app/javascript/application.js` | Loads Turbo, Active Storage, WebAuthn helpers, Chart.js registration, and Stimulus controllers. |
| Stimulus registry | `app/javascript/controllers/index.js` | Imports and registers every production controller. Dynamically registers `debug` only when `NODE_ENV=development`. |
| Request service | `app/javascript/services/rails_request.js` | Wraps `@rails/request.js` for JSON-style requests, cancellation, and response parsing. |
| Constituent application forms | `app/views/constituent_portal/applications/new.html.erb`, `edit.html.erb` | Attach `autosave`, `currency-formatter`, `final-submit-gate`, and conditionally `income-validation` and `dependent-fields`. |
| Admin paper application form | `app/views/admin/paper_applications/new.html.erb` | Attaches `paper-application`, `applicant-type`, and conditionally `income-validation`. |
| Charts | `app/views/admin/applications/_charts_section.html.erb`, `app/views/admin/reports/index.html.erb`, `app/views/vendor_portal/dashboard/show.html.erb` | Use `reports-chart`, `chart`, and `chart-toggle` controllers. |
| Flash | `app/views/layouts/application.html.erb`, `app/views/shared/_flash.html.erb` | Layout renders `#flash`; Turbo helpers update it with `shared/flash`. |

Relevant routes:

| Route | Controller Action | JS Caller |
|-------|-------------------|-----------|
| `PATCH /constituent_portal/applications/autosave_field` | `ConstituentPortal::ApplicationsController#autosave_field` | `forms/autosave_controller.js` |
| `PATCH /constituent_portal/applications/:id/autosave_field` | `ConstituentPortal::ApplicationsController#autosave_field` | `forms/autosave_controller.js` |
| `GET /admin/paper_applications/recipient_preference` | `Admin::PaperApplicationsController#recipient_preference` | `forms/paper_application_controller.js` |
| `GET /admin/applications/charts` | `Admin::ApplicationsController#charts` | Lazy Turbo frame that mounts `reports-chart` |

---

## Core Services

### `rails_request`

```javascript
// app/javascript/services/rails_request.js
const result = await railsRequest.perform({
  method: "patch",
  url: "/constituent_portal/applications/123/autosave_field",
  body: { field_name: "application[household_size]", field_value: "3" },
  key: "autosave-application"
})

if (result.success) {
  // result.data is parsed from JSON, HTML, Turbo Stream, or text response bodies.
}
```

Behavior:

- Exports `RailsRequestService`, `RequestError`, and the singleton `railsRequest`.
- Tracks active requests by optional `key`; a duplicate key cancels the earlier request.
- Supports `cancel(key)` and `cancelAll()`.
- Serializes object bodies as JSON strings; string bodies pass through unchanged.
- Parses JSON, HTML, Turbo Stream, and fallback text from a cloned response when possible.
- Returns `{ success: false, aborted: true }` for `AbortError`.
- Raises `RequestError` for non-OK HTTP responses.
- In development, rejects requests whose `Accept` header asks for HTML. Use Turbo frames/streams for HTML responses.
- `tryShowFlash` is a no-op. Rails-rendered flash remains the user-facing feedback path.

Use `railsRequest` for JSON-style Rails endpoints such as autosave, role updates, credential setup, and admin user search. Direct `fetch` handles flows that need a narrow response contract, such as WebAuthn options, adult/guardian picker lookups, address autocomplete, and paper rejection recipient preference.

### `chart_config`

```javascript
const config = chartConfig.getConfigForType("bar")
const datasets = chartConfig.createDatasets([
  { label: "Current FY", data: [1, 2, 3] }
])
```

- Provides fixed-size Chart.js defaults: `responsive: false`, `maintainAspectRatio: false`.
- Provides minimal per-type options for bar, line, and doughnut charts.
- Creates one or more datasets with standard colors.
- Provides a deep `mergeOptions` helper and a compact legend-free config.
- Provides a currency formatter.

### `income_threshold`

```javascript
import { calculateThreshold, exceeds } from "../services/income_threshold"

const threshold = calculateThreshold({
  baseFplBySize: { "1": 15650, "2": 21150 },
  modifierPercent: 400,
  householdSize: 2
})

const overLimit = exceeds({
  baseFplBySize: { "1": 15650, "2": 21150 },
  modifierPercent: 400,
  householdSize: 2,
  income: 90000
})
```

- Pure DOM-free helper used by `forms/income_validation_controller.js`.
- Uses server-rendered base FPL values and modifier values from `IncomeThresholdCalculationService`.
- Caps household sizes above 8 to match the server-side FPL lookup.

---

## Form Controllers

| Controller | Path | Responsibility |
|------------|------|------------------------|
| `BaseFormController` | `app/javascript/controllers/base/form_controller.js` | Shared async form submit helper for controllers that opt into `railsRequest`; handles loading state, local status text, field errors, cancellation, and validation hooks. |
| `autosave` | `app/javascript/controllers/forms/autosave_controller.js` | Saves individual fields on blur through the constituent autosave route. Updates form URLs after a new draft is created. |
| `income-validation` | `app/javascript/controllers/forms/income_validation_controller.js` | Calculates FPL threshold state, owns the warning container, updates the income field group styling, and dispatches validation events. |
| `final-submit-gate` | `app/javascript/controllers/forms/final_submit_gate_controller.js` | Gates constituent final submit buttons from required checkboxes, required visible non-file fields, checkbox groups, and income validation events. |
| `paper-application` | `app/javascript/controllers/forms/paper_application_controller.js` | Gates admin paper submit from income state, existing-adult verification, required attestations, visible required fields, required proof radio groups, checkbox groups, and medical provider requirements. Also populates the income-rejection dialog. |
| `applicant-type` | `app/javascript/controllers/users/applicant_type_controller.js` | Shows the adult or dependent-with-guardian path and dispatches `applicant-type:applicantTypeChanged`. |
| `dependent-fields` | `app/javascript/controllers/forms/dependent_fields_controller.js` | Shows dependent fields and copies guardian address/email/phone values when requested. |

`BaseFormController#collectFormData` returns a flat object. It supports array fields named `field[]`, but it does not parse Rails nested parameter names into nested objects. A field named `guardian_attributes[name]` remains the key `"guardian_attributes[name]"`.

---

## Income Validation Flow

`income-validation` has one source of truth for threshold display state. Submit button state is owned by form-specific gate controllers.

1. Rails renders `data-income-validation-fpl-thresholds-value` and `data-income-validation-modifier-value` from `fpl_thresholds_json` and `fpl_modifier_value`.
2. `income-validation` parses those values on connect, marks the element with `data-fpl-loaded="true"`, and validates the initial state.
3. It listens to household size, annual income, and currency formatter events.
4. It calls `income_threshold.calculateThreshold`.
5. It shows or hides `[data-income-validation-target="warningContainer"]`, including the HTML `hidden` attribute and `role="alert"` state.
6. It dispatches `income-validation:validated` with `{ exceedsThreshold, income, threshold, householdSize }`.
7. `final-submit-gate` and `paper-application` listen to that event and combine it with their other submit-gating rules.

Form wiring:

| Form | Income Controller Wiring |
|------|--------------------------|
| Constituent new application | Includes `income-validation` when `FeatureFlag.income_proof_required?` is true. That predicate derives from `vouchers_enabled`; there is no separate `income_proof_required` feature-flag row. |
| Constituent edit application | Includes `income-validation` when `@application.income_collection_enabled?` is true. |
| Admin paper application | Includes `income-validation` when `FeatureFlag.income_proof_required?` is true. |

Warning containers render hidden by default. The constituent form uses `#income-threshold-warning`; the admin paper form uses `#admin-income-threshold-warning`. Tests should prefer `[data-income-validation-target="warningContainer"]` when the specific ID is not part of the behavior under test.

---

## Event-Driven Workflows

Stimulus `dispatch("name")` prefixes events with the controller identifier. For example, `this.dispatch("validated")` in `income-validation` emits `income-validation:validated`.

```javascript
// Dispatch
this.dispatch("selectionChange", { detail: { guardianId: 123 } })

// Listen
this.element.addEventListener(
  "guardian-picker:selectionChange",
  this.handleGuardianSelection.bind(this)
)
```

Event paths:

| Event | Dispatcher | Listener |
|-------|------------|----------|
| `income-validation:validated` | `income-validation` | `paper-application`, `final-submit-gate` |
| `income-validation:fpl-data-loaded` | `income-validation` | System/helper checks use it as a loaded signal. |
| `applicant-type:applicantTypeChanged` | `applicant-type` | `dependent-fields` |
| `guardian-picker:selectionChange` | `guardian-picker` | `applicant-type`; admin paper form also wires it through data actions. |
| `adult-picker:selectionChange`, `adult-picker:verificationChange`, `adult-picker:createNew` | `adult-picker` | `applicant-type`, `paper-application` |
| `visibility-changed` | `chart-toggle` | Nested `chart` controllers |

---

## Flash Feedback

Use Rails flash for transient page messages.

- `ApplicationController` adds `info`, `error`, `success`, and `warning` flash types.
- `app/views/layouts/application.html.erb` renders `<div id="flash">`.
- `app/views/shared/_flash.html.erb` renders messages with `role="alert"` and `aria-live="polite"`.
- `TurboStreamResponseHandling` updates `#flash` with `shared/flash` for Turbo Stream responses.
- JavaScript should not create a separate toast layer. Dynamic client flows that need a user-visible message should update server-rendered flash or local inline status text.

---

## Chart.js Integration

`app/javascript/application.js` imports Chart.js modules, registers the controllers/elements/scales/plugins in use, disables animation and responsive resizing globally, and exposes `window.Chart` for Stimulus controllers.

Chart behavior:

- Charts use explicit canvas dimensions from `ChartBaseController#applyContainerDimensions`.
- `Chart.defaults.responsive` is `false`; controller configs keep `responsive: false`.
- The app does not patch `window.getComputedStyle`. Comments in `application.js` explicitly avoid that patch because Chart.js uses computed style during interactions.
- `reports-chart` serializes initialization through `ReportsChartController.initQueue`, waits for `requestAnimationFrame`, and reschedules if the container is still hidden.
- `reports-chart` disables Chart.js pointer events with `options.events = []`.
- `chart-toggle` dispatches `visibility-changed` when revealing nested `chart` controllers.
- Chart containers should have real dimensions in ERB/CSS before the controller initializes.

---

## Controller Organization

```text
app/javascript/controllers/
|-- admin/
|-- auth/
|-- base/
|-- charts/
|-- forms/
|-- reviews/
|-- ui/
`-- users/
```

All production controllers are registered explicitly in `app/javascript/controllers/index.js`. New controller files require a matching import and `application.register(...)` entry.

---

## Tests

Frontend tests use Jest with jsdom.

- Config: `jest.config.js`
- Setup: `test/javascript/setup.js`
- Command: `yarn test`
- Test roots: `test/javascript`

Test coverage includes services (`rails_request`, `chart_config`), utilities (`visibility`, `debounce`), and key controllers such as base form, chart/report rendering, chart toggle, paper application gating, final submit gating, upload, admin user search, applicant type, adult picker, guardian picker, contact feedback, rejection form, and visibility.

Rails/system coverage also exercises JS-wired flows, including admin paper applications, constituent income threshold behavior, dashboard charts, proof uploads, and vendor chart toggles.
