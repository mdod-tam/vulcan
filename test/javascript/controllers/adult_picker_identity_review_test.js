/**
 * The identity-review entry point on the adult picker.
 *
 * Its whole reason for existing is that the ordinary selectAdult is unsafe here: it takes display
 * *markup* and selects unconditionally. So the properties worth pinning are the refusals -- an
 * ineligible or unverifiable candidate must not end up selected -- and the ordering, because
 * announcing a selection before the verification control exists lets submit gating conclude that
 * verification is unnecessary.
 */
import AdultPickerController from "../../../app/javascript/controllers/users/adult_picker_controller"

jest.mock("../../../app/javascript/utils/debounce", () => ({ debouncedDispatch: jest.fn() }))

describe("selectAdultFromIdentityReview", () => {
  let controller

  function contextResponse(payload) {
    return Promise.resolve({
      ok: true,
      json: () => Promise.resolve({ success: true, user: { id: 7 }, ...payload })
    })
  }

  beforeEach(() => {
    document.body.innerHTML = `
      <div>
        <button type="button" id="use-this-constituent">Use this constituent</button>
        <input name="existing_constituent_id">
        <div class="selected-pane">
          <h3 id="adult-picker-selected-heading" tabindex="-1">Applicant Selected</h3>
          <div class="adult-details-container"></div>
        </div>
      </div>`

    // Stimulus exposes element and targets as prototype getters, so they are defined rather than
    // assigned on this bare instance.
    controller = Object.create(AdultPickerController.prototype)
    const define = (name, value) => Object.defineProperty(controller, name, { value, configurable: true })
    define("element", document.querySelector("div"))
    define("selectedPaneTarget", document.querySelector(".selected-pane"))
    define("constituentIdFieldTarget", document.querySelector('[name="existing_constituent_id"]'))
    define("hasConstituentIdFieldTarget", true)
    define("selectedHeadingTarget", document.querySelector("#adult-picker-selected-heading"))
    define("hasSelectedHeadingTarget", true)

    controller.togglePanes = jest.fn()
    controller.dispatchSelectionChange = jest.fn()
    controller._applyAdultContext = jest.fn()
  })

  afterEach(() => {
    delete global.fetch
    document.body.innerHTML = ""
  })

  test("an eligible candidate is selected only after the context is applied", async () => {
    global.fetch = jest.fn(() => contextResponse({ eligible_now: true }))
    const order = []
    controller._applyAdultContext = jest.fn(() => order.push("context"))
    controller.dispatchSelectionChange = jest.fn(() => order.push("announced"))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome).toEqual({ selected: true })
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("7")
    // Verification controls must exist before anything reacts to the selection.
    expect(order).toEqual(["context", "announced"])
  })

  // Selecting tears down the panel the focused button lived in. Without an explicit move, focus
  // falls back to <body>, returning a keyboard or screen-reader user to the top of a long form with
  // no indication that anything happened.
  test("selecting moves focus to the selected-applicant heading", async () => {
    global.fetch = jest.fn(() => contextResponse({ eligible_now: true }))
    document.querySelector("#use-this-constituent").focus()
    expect(document.activeElement.id).toBe("use-this-constituent")

    await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(document.activeElement.id).toBe("adult-picker-selected-heading")
  })

  // A refusal leaves the panel standing, so the button staff pressed is still there and still where
  // focus belongs. Moving it would be the defect in the other direction.
  test("a refused selection does not move focus", async () => {
    global.fetch = jest.fn(() => contextResponse({ eligible_now: false, ineligibility_reason: "active_application" }))
    document.querySelector("#use-this-constituent").focus()

    await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(document.activeElement.id).toBe("use-this-constituent")
  })

  test("an active application leaves the candidate unselected", async () => {
    global.fetch = jest.fn(() => contextResponse({
      eligible_now: false, ineligibility_reason: "active_application"
    }))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome.selected).toBe(false)
    expect(outcome.reason).toMatch(/already has an active application/i)
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
    expect(controller.dispatchSelectionChange).not.toHaveBeenCalled()
  })

  // The payload carries eligible_after, not eligible_date. Reading the wrong key described every
  // waiting-period candidate as having an active application.
  test("a waiting-period candidate reports the waiting period and its date", async () => {
    global.fetch = jest.fn(() => contextResponse({
      eligible_now: false, ineligibility_reason: "waiting_period", eligible_after: "2027-04-02"
    }))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome.selected).toBe(false)
    expect(outcome.reason).toMatch(/waiting period/i)
    // The exact date, not just the year. A date-only value parses as UTC midnight, so formatting it
    // in local time renders the previous day and tells staff someone is eligible a day early.
    expect(outcome.reason).toContain("April 2, 2027")
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
  })

  test("a failed eligibility check leaves the candidate unselected", async () => {
    global.fetch = jest.fn(() => Promise.reject(new Error("network down")))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome.selected).toBe(false)
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
    expect(controller._applyAdultContext).not.toHaveBeenCalled()
  })

  test("a malformed eligibility response leaves the candidate unselected", async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true, json: () => Promise.resolve({ success: false })
    }))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome.selected).toBe(false)
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
  })

  // Fails closed. A successful response that simply omits the field -- a shape change, a partial
  // payload -- must not be read as permission.
  test("a response missing eligible_now is not treated as eligible", async () => {
    global.fetch = jest.fn(() => Promise.resolve({
      ok: true, json: () => Promise.resolve({ success: true, user: { id: 7 } })
    }))

    const outcome = await controller.selectAdultFromIdentityReview({ id: 7, name: "Jane Doe" })

    expect(outcome.selected).toBe(false)
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
    expect(controller.dispatchSelectionChange).not.toHaveBeenCalled()
  })

  // Staff edited the applicant while eligibility was loading, so the answer no longer applies.
  test("an aborted check selects nothing even after it resolves", async () => {
    const abort = new AbortController()
    global.fetch = jest.fn(() => {
      abort.abort()
      return contextResponse({ eligible_now: true })
    })

    const outcome = await controller.selectAdultFromIdentityReview(
      { id: 7, name: "Jane Doe" }, { signal: abort.signal }
    )

    expect(outcome.selected).toBe(false)
    expect(document.querySelector('[name="existing_constituent_id"]').value).toBe("")
    expect(controller.dispatchSelectionChange).not.toHaveBeenCalled()
  })

  test("candidate values render as text, not markup", async () => {
    global.fetch = jest.fn(() => contextResponse({ eligible_now: true }))

    await controller.selectAdultFromIdentityReview({
      id: 7, name: "<img src=x onerror=alert(1)>", date_of_birth: "April 2, 1990"
    })

    const box = document.querySelector(".adult-details-container")
    expect(box.querySelector("img")).toBeNull()
    expect(box.textContent).toContain("<img src=x onerror=alert(1)>")
  })
})
