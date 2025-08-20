# JavaScript Architecture

A concise reference to the Stimulus-based, service-driven JS layer that powers our Rails app.

---

## 1 · Core Ideas

| Principle | In Practice |
|-----------|-------------|
| **Centralized services** | One request / chart / notification service used by every controller. |
| **Base controllers** | Shared form & chart logic via inheritance (`BaseFormController`, `ChartBaseController`). |
| **Target safety** | Target safety mixin provides safe target access with warnings. |
| **Event-driven** | Controllers communicate through custom events, not direct calls. |
| **Fail-fast** | Missing targets & unhandled errors surface immediately. |

---

## 2 · Key Services

### 2.1 · `rails_request`

```javascript
// app/javascript/services/rails_request.js
const result = await railsRequest.perform({
  method: 'patch',
  url:    '/api/users/123',
  body:   { name: 'John' },
  key:    'user-update'          // duplicates auto-cancelled
})
if (result.success) { ... } else if (!result.aborted) { ... }
```

* Singleton export: `railsRequest` (cancellable by `key`, plus `cancel`/`cancelAll`).  
* Safe response parsing for JSON and HTML/Turbo Streams with body clone fallback to avoid `bodyUsed` errors.  
* Global `unhandledrejection` handler suppresses the known `@rails/request.js` JSON parsing warning when HTML is returned.  
* Basic scaffolding for upload progress hooks (not widely used in production flows).  
* Uses server-rendered Rails flash for user-visible messages. Client-side code does not show toasts.

### 2.2 · `chart_config`

```javascript
const config   = chartConfig.getConfigForType('bar')
const datasets = chartConfig.createDatasets([{ label: 'YTD', data }])
```

* Simplified configuration focused on reliability.  
* Basic color schemes and formatters.  
* Non-responsive behavior to prevent resize loops.

### 2.3 · Notifications (Rails Flash)

```ruby
# Controller
redirect_to users_path, notice: 'User created successfully'

# Turbo Stream
flash.now[:error] = 'Validation failed'
render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
```

* Rails built-in flash is the only supported in-app notification mechanism.
* No JavaScript toast layer is present to reduce complexity and improve accessibility.

### 2.4 · Utility Modules

| Utility | Purpose |
|---------|---------|
| `utils/visibility.js` | `setVisible(el, bool, { required })` → toggles `hidden` & `required`. |
| `utils/debounce.js`   | Pre-tuned debounce fns (`createSearchDebounce`, `createFormChangeDebounce`, `createUIUpdateDebounce`, …). |

---

### 2.5 · `income_threshold` (FPL)

```javascript
// app/javascript/services/income_threshold.js
import { calculateThreshold, exceeds } from "../services/income_threshold"

const baseFplBySize = { "1": 15650, "2": 21150 /* ... up to 8 */ }
const modifierPercent = 400

const threshold = calculateThreshold({ baseFplBySize, modifierPercent, householdSize: 3 })
const isOver    = exceeds({ baseFplBySize, modifierPercent, householdSize: 3, income: 110000 })
```

- Pure, DOM-free functions mirroring server `IncomeThresholdCalculationService` inputs/semantics.
- DRY threshold math across constituent and admin paper application flows.
- Easy to unit test without Stimulus or DOM.

Ownership & events
- `income-validation` controller owns threshold assessment and the warning container visibility.
- It dispatches `income-validation:validated` with `{ exceedsThreshold, income, threshold, householdSize }`.
- `paper-application` listens to the event to toggle submit/reject UI; it does not modify the warning container.

Visibility & selectors
- Warning containers render with HTML `hidden` initially for deterministic headless runs.
- Controllers add/remove `hidden` and set `role="alert"` when visible.
- Prefer `[data-income-validation-target="warningContainer"]` in tests; constituent keeps `#income-threshold-warning`, admin uses `#admin-income-threshold-warning`.

---

## 3 · Base Controllers

### 3.1 · `BaseFormController`

* Loader button states, field-level errors, status flash.  
* Integrates `rails_request`; overrides: `validateBeforeSubmit`, `handleSuccess`, `handleError`.
* Automatic form data collection with array field support.

```javascript
class UserFormController extends BaseFormController {
  async validateBeforeSubmit(data) {
    return data.email ? { valid: true } : { valid: false, errors: { email: 'Required' } }
  }
  handleSuccess(data) { this.showStatus('Saved', 'success') }
}
```

### 3.2 · `ChartBaseController`

* Creates `<canvas>` with accessibility features, destroys Chart.js instance on disconnect.
* Pulls defaults from `chart_config`, handles data validation.
* Debounced resize handling and error management.

---

## 4 · Target Safety

```javascript
import { applyTargetSafety } from "../mixins/target_safety"

class MyController extends Controller {
  static targets = ['submit', 'status']
  
  save() {
    const btn = this.safeTarget('submit')
    if (btn) btn.disabled = true
  }
}
applyTargetSafety(MyController)
```

* `safeTarget()` and `safeTargets()` helpers with optional warnings.  
* Development-time warnings for missing targets.

HTML pattern:

```erb
<form data-controller="my" data-my-target="form">
  <button data-my-target="submit">Save</button>
  <div   data-my-target="status"></div>
</form>
```

---

## 5 · Flash Notifications

* Use Rails flash for in-app messages (notice/alert/info/warning/success).
* For Turbo Stream responses, set `flash.now[...]` and update the `#flash` frame with `shared/flash`.
* Dynamic client actions that need user feedback should update the `#flash` container.

---

## 6 · Event-Driven Workflows

Controllers communicate through custom events:

```javascript
// Dispatch event
this.element.addEventListener('income-validation:validated', this.handleIncomeValidation.bind(this))

// Listen for events
this.dispatch('selectionChange', { detail: { guardianId: 123 } })
```

Example: Paper application flow uses events between `income-validation`, `dependent-fields`, and `applicant-type` controllers.

Income validation flow
- `income-validation` computes using server-injected thresholds (`fpl_thresholds_json`, `fpl_modifier_value`) and the shared `income_threshold` utility, then dispatches `income-validation:validated`.
- `paper-application` listens for that event to disable/enable submit and to show/hide its rejection action.
- Only `income-validation` toggles the warning container. In tests, assert visibility via `[data-income-validation-target="warningContainer"]` and the `[hidden]` attribute.

---

## 7 · Form Data Handling

```javascript
// BaseFormController automatically handles form data collection
collectFormData() {
  const formData = new FormData(this.formTarget)
  // Converts to object with array field support
  // guardian_attributes[name] → { guardian_attributes: { name: "value" } }
}
```

* Automatic array field handling (`field[]` → array).  
* JSON serialization for API requests.
* Built into `BaseFormController`.

---

## 8 · Chart.js Integration

```javascript
// application.js - Tree-shaken Chart.js imports
import { Chart, BarController, LineController, ... } from 'chart.js'

// Global Chart availability with recursion protection
window.Chart = Chart
```

* Tree-shaken imports for production optimization.
* Global recursion protection via a `getComputedStyle` override with a depth guard to prevent infinite measurement recursion in production and tests.
* Disabled responsive/animation by default for stability; controllers size canvases explicitly.

---

## 9 · Controller Organization

Controllers are organized by domain:

```
controllers/
├── admin/          # Admin-specific controllers
├── auth/           # Authentication controllers  
├── base/           # Base classes (BaseFormController)
├── charts/         # Chart controllers + ChartBaseController
├── forms/          # Form-specific controllers
├── reviews/        # Review workflow controllers
├── ui/             # UI component controllers
└── users/          # User management controllers
```

All controllers registered in `controllers/index.js` with consistent naming.
Development-only `debug_controller` is conditionally loaded when `NODE_ENV=development`.

---

## 10 · Production Safeguards

| Concern | Mitigation |
|---------|------------|
| Excess logs | `if (process.env.NODE_ENV !== 'production') { console.log(...) }` |
| Chart leaks | `chartInstance.destroy()` in `disconnect()` |
| Request leaks | Pass a `key`, call `railsRequest.cancel(key)` in `disconnect()` |
| Accessibility | All dynamic elements get ARIA roles / SR-friendly updates |
| Memory leaks | Proper event listener cleanup in `disconnect()` |

---

## 11 · Development Features

* **Debug controller** (development-only) for diagnostics.
* **Target safety warnings** in development mode.
* **Request service logging** for debugging API calls.
* Controllers clean up event listeners in `disconnect()` to avoid leaks.

---

## 12 · Current Architecture Status

✅ **Implemented:**
- All core services (`rails_request`, `chart_config`)
- Base controllers with inheritance patterns
- Target safety mixin with development warnings  
- Event-driven communication between controllers
- Comprehensive controller organization by domain
- Chart.js integration with tree-shaking and stability fixes

🔄 **In Progress:**
- Expanding test coverage for utilities and services
- Refining form validation patterns in `BaseFormController`