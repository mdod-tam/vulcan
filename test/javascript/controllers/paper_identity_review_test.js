/**
 * Identity review interaction.
 *
 * The contracts worth protecting here are mostly about what must *not* happen: no files uploaded to
 * a check, no bypass surviving its own call, no stale answer painting a panel, no markup executed
 * from server data. Each of those fails silently in a browser, so they are pinned rather than
 * observed.
 */
import { Application } from "@hotwired/stimulus"
import PaperApplicationController from "../../../app/javascript/controllers/forms/paper_application_controller"

// No mock. Visibility is the thing that broke -- the ERB used the native hidden attribute while
// setVisible toggles a class -- and a handwritten stand-in is exactly what let that pass. These
// assertions run through the real helper so "the panel becomes visible" means it does.

const IDENTITY_FIELDS = [
  "first_name", "last_name", "date_of_birth", "email", "phone",
  "physical_address_1", "physical_address_2", "city", "state", "zip_code"
]

function buildForm({ existingConstituentId = "", applicantType = "self" } = {}) {
  document.body.innerHTML = `
    <meta name="csrf-token" content="test-csrf">
    <form data-controller="paper-application"
          data-action="submit->paper-application#beforeSubmit"
          data-paper-application-identity-review-url-value="/admin/paper_applications/identity_review">
      <input type="radio" name="applicant_type" value="${applicantType}" checked>
      <input name="existing_constituent_id" value="${existingConstituentId}">
      ${IDENTITY_FIELDS.map((f) => `<input name="constituent[${f}]" value="${f}-value">`).join("")}
      <input type="hidden" name="no_email_address" value="0">
      <input type="checkbox" name="no_email_address" value="1">
      <input type="hidden" name="no_phone_number" value="0">
      <input type="checkbox" name="no_phone_number" value="1">
      <input type="file" name="income_proof">
      <section class="hidden" style="display: none;" data-paper-application-target="identityReviewPanel">
        <h3 tabindex="-1" data-paper-application-target="identityReviewHeading"></h3>
        <p data-paper-application-target="identityReviewBody"></p>
        <ul data-paper-application-target="identityReviewCandidates"></ul>
        <div class="hidden" style="display: none;" data-paper-application-target="identityReviewOverride"></div>
        <p class="hidden" style="display: none;" tabindex="-1" data-paper-application-target="identityReviewNotice"></p>
      </section>
      <input type="hidden" name="identity_decision" data-paper-application-target="identityDecision">
      <p data-paper-application-target="status"></p>
      <button type="submit" data-paper-application-target="submitButton">Submit</button>
    </form>`
  return document.querySelector("form")
}

async function startApplication() {
  const application = Application.start()
  application.register("paper-application", PaperApplicationController)
  await new Promise((resolve) => setTimeout(resolve, 0))
  return application
}

function controllerFor(application, form) {
  return application.getControllerForElementAndIdentifier(form, "paper-application")
}

function jsonResponse(payload) {
  return Promise.resolve({
    ok: true,
    headers: { get: () => "application/json" },
    json: () => Promise.resolve(payload)
  })
}

describe("paper identity review", () => {
  let application
  let form

  // jsdom has no fetch, so it is installed before anything spies on it.
  beforeEach(() => {
    global.fetch = jest.fn(() => jsonResponse({ state: "clear", candidates: [] }))
  })

  afterEach(() => {
    if (application) application.stop()
    jest.restoreAllMocks()
    delete global.fetch
    document.body.innerHTML = ""
  })

  describe("when the review runs", () => {
    beforeEach(async () => {
      form = buildForm()
      application = await startApplication()
      form.requestSubmit = jest.fn()
    })

    test("sends only the ten identity facts and the two flags, and no File", async () => {
      const fetchMock = jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({ state: "clear", candidates: [] }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const body = fetchMock.mock.calls[0][1].body
      const keys = [...body.keys()].sort()
      expect(keys).toEqual([
        ...IDENTITY_FIELDS.map((f) => `constituent[${f}]`),
        "no_email_address",
        "no_phone_number"
      ].sort())
      expect([...body.values()].some((value) => value instanceof File)).toBe(false)
    })

    test("reads the no-contact flags from the checkbox, not the hidden field before it", async () => {
      document.querySelectorAll('input[type="checkbox"]').forEach((box) => { box.checked = true })
      const fetchMock = jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({ state: "clear", candidates: [] }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const body = fetchMock.mock.calls[0][1].body
      expect(body.get("no_email_address")).toBe("1")
      expect(body.get("no_phone_number")).toBe("1")
    })

    test("a clear answer resumes the native submission exactly once", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({ state: "clear", candidates: [] }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      expect(form.requestSubmit).toHaveBeenCalledTimes(1)
    })

    test("the bypass does not survive the call that used it", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({ state: "clear", candidates: [] }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      expect(controllerFor(application, form)._identityReviewBypass).toBe(false)
    })

    test("candidate values are rendered as text, including hostile markup", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "<img src=x onerror=alert(1)>", date_of_birth: "April 2, 1990", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const list = form.querySelector('[data-paper-application-target="identityReviewCandidates"]')
      expect(list.querySelector("img")).toBeNull()
      expect(list.textContent).toContain("<img src=x onerror=alert(1)>")
    })

    test("a token is not written to the hidden field until staff override", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc",
        expires_at: new Date(Date.now() + 60000).toISOString()
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const hidden = form.querySelector('[data-paper-application-target="identityDecision"]')
      expect(hidden.value).toBe("")

      controllerFor(application, form).overrideIdentityReview()
      expect(hidden.value).toBe("v1:1:abc")
      expect(form.requestSubmit).toHaveBeenCalled()
    })

    test("a blocked answer offers no override", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "blocked",
        candidates: [{ id: 2, name: "Existing Person", selectable: false }],
        reasons: ["exact_email"]
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const override = form.querySelector('[data-paper-application-target="identityReviewOverride"]')
      expect(override.classList.contains("hidden")).toBe(true)
      expect(form.requestSubmit).not.toHaveBeenCalled()
    })

    test("a stale response cannot repaint the panel", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => new Promise((resolve) => {
        setTimeout(() => resolve({
          ok: true,
          headers: { get: () => "application/json" },
          json: () => Promise.resolve({
            state: "needs_confirmation",
            candidates: [{ id: 9, name: "Stale Person", selectable: true }],
            reasons: ["name_dob"],
            token: "v1:1:stale"
          })
        }), 10)
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      // Staff edit the applicant while the answer is in flight.
      form.querySelector('[name="constituent[first_name]"]').value = "Someone Else"
      await new Promise((resolve) => setTimeout(resolve, 30))

      const list = form.querySelector('[data-paper-application-target="identityReviewCandidates"]')
      expect(list.textContent).not.toContain("Stale Person")

      // Changing .value dispatches no event, so nothing invalidates: the answer is discarded on the
      // snapshot alone. That path has to settle the state too, or Submit stays disabled forever.
      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("idle")
      expect(form.querySelector('[data-paper-application-target="submitButton"]').disabled).toBe(false)
    })

    // Hiding the panel left its rows in place, so the next thing to show it -- an error after staff
    // edited the applicant -- displayed the previous applicant's candidates and an override button.
    test("an error after an edit cannot resurrect the previous candidates", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Previous Applicant", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const field = form.querySelector('[name="constituent[first_name]"]')
      field.value = "Someone Different"
      field.dispatchEvent(new Event("input", { bubbles: true }))

      global.fetch.mockImplementation(() => Promise.reject(new Error("network down")))
      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const panel = form.querySelector('[data-paper-application-target="identityReviewPanel"]')
      expect(panel.textContent).not.toContain("Previous Applicant")
      expect(form.querySelector('[data-paper-application-target="identityReviewOverride"]')
        .classList.contains("hidden")).toBe(true)
    })

    // The wiring exists for the custom Stimulus event, but nothing dispatched it until now.
    test("the custom applicant-type change event invalidates the review", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))
      expect(controllerFor(application, form)._identityReviewState).toBe("possible_matches")

      form.dispatchEvent(new CustomEvent("applicant-type:applicantTypeChanged", { bubbles: true }))

      expect(controllerFor(application, form)._identityReviewState).toBe("idle")
    })

    test("a non-JSON response is treated as an error rather than parsed", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => Promise.resolve({
        ok: true,
        headers: { get: () => "text/html" },
        json: () => Promise.reject(new Error("should not be called"))
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("error")
      // Error leaves Submit usable as the retry.
      expect(controller._identityReviewBlocksSubmit()).toBe(false)
    })

    test("review state participates in submit gating", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      expect(form.querySelector('[data-paper-application-target="submitButton"]').disabled).toBe(true)

      // A later input event recomputes gating from scratch; the review state must survive it.
      form.dispatchEvent(new Event("input", { bubbles: true }))
      expect(form.querySelector('[data-paper-application-target="submitButton"]').disabled).toBe(true)
    })

    // The panel has to actually become visible. An earlier version used the native hidden attribute
    // while setVisible toggles a class, so both panels stayed invisible in a browser while this
    // suite passed.
    test("the decision panel becomes visible by the same mechanism production uses", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      const panel = form.querySelector('[data-paper-application-target="identityReviewPanel"]')
      expect(panel.classList.contains("hidden")).toBe(true)

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      expect(panel.classList.contains("hidden")).toBe(false)
      expect(panel.style.display).not.toBe("none")
      const override = form.querySelector('[data-paper-application-target="identityReviewOverride"]')
      expect(override.classList.contains("hidden")).toBe(false)
    })

    // Editing during the request previously left the state at `checking`, which disabled Submit
    // permanently: the answer was discarded as stale but nothing moved the state back.
    test("editing an identity fact during the check returns Submit to usable", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => new Promise((resolve) => {
        setTimeout(() => resolve({
          ok: true,
          headers: { get: () => "application/json" },
          json: () => Promise.resolve({ state: "needs_confirmation", candidates: [], reasons: [], token: "v1:1:x" })
        }), 10)
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("checking")

      const field = form.querySelector('[name="constituent[first_name]"]')
      field.value = "Edited"
      field.dispatchEvent(new Event("input", { bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 30))

      expect(controller._identityReviewState).toBe("idle")
      expect(form.querySelector('[data-paper-application-target="submitButton"]').disabled).toBe(false)
    })

    test("editing an identity fact after a panel appears clears the panel and the token", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc",
        expires_at: new Date(Date.now() + 60000).toISOString()
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      controller.overrideIdentityReview()
      expect(form.querySelector('[data-paper-application-target="identityDecision"]').value).toBe("v1:1:abc")

      const field = form.querySelector('[name="constituent[last_name]"]')
      field.value = "Changed"
      field.dispatchEvent(new Event("input", { bubbles: true }))

      expect(controller._identityReviewState).toBe("idle")
      expect(form.querySelector('[data-paper-application-target="identityDecision"]').value).toBe("")
      expect(form.querySelector('[data-paper-application-target="identityReviewPanel"]').classList.contains("hidden")).toBe(true)
    })

    test("toggling a no-contact flag invalidates the review", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation", candidates: [], reasons: [], token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const box = form.querySelector('input[type="checkbox"][name="no_email_address"]')
      box.checked = true
      box.dispatchEvent(new Event("change", { bubbles: true }))

      expect(controllerFor(application, form)._identityReviewState).toBe("idle")
    })

    test("an unrelated field does not discard a valid review", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc"
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const unrelated = document.createElement("input")
      unrelated.name = "application[annual_income]"
      form.appendChild(unrelated)
      unrelated.dispatchEvent(new Event("input", { bubbles: true }))

      expect(controllerFor(application, form)._identityReviewState).toBe("possible_matches")
    })

    // Expiry has to be visible, not just announced to a screen reader.
    test("an expired review shows a visible, focusable message and frees Submit", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc",
        expires_at: new Date(Date.now() - 1000).toISOString()
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("expired")

      const notice = form.querySelector('[data-paper-application-target="identityReviewNotice"]')
      expect(notice.classList.contains("hidden")).toBe(false)
      expect(notice.textContent).toMatch(/Review expired/i)
      expect(form.querySelector('[data-paper-application-target="submitButton"]').disabled).toBe(false)
      expect(form.querySelector('[data-paper-application-target="identityDecision"]').value).toBe("")
    })

    test("an override after the deadline is refused rather than applied", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
        state: "needs_confirmation",
        candidates: [{ id: 1, name: "Jane Doe", selectable: true }],
        reasons: ["name_dob"],
        token: "v1:1:abc",
        expires_at: new Date(Date.now() + 50).toISOString()
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))
      // A suspended tab can delay the timer past the deadline, so the override re-checks it.
      await new Promise((resolve) => setTimeout(resolve, 80))

      const controller = controllerFor(application, form)
      form.requestSubmit.mockClear()
      controller.overrideIdentityReview()

      expect(form.querySelector('[data-paper-application-target="identityDecision"]').value).toBe("")
      expect(form.requestSubmit).not.toHaveBeenCalled()
    })

    test("an error shows a visible message", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => Promise.reject(new Error("network down")))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const notice = form.querySelector('[data-paper-application-target="identityReviewNotice"]')
      expect(notice.classList.contains("hidden")).toBe(false)
      expect(notice.textContent).toMatch(/Submit again to retry/i)
    })

    // `checking` is the one state that also disables Submit. Announcing it only to screen readers
    // left sighted staff watching a button that had silently stopped working.
    test("the checking state is visible, not only announced", async () => {
      let settle
      jest.spyOn(global, "fetch").mockImplementation(() => new Promise((resolve) => { settle = resolve }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      const notice = form.querySelector('[data-paper-application-target="identityReviewNotice"]')
      expect(controller._identityReviewState).toBe("checking")
      expect(notice.classList.contains("hidden")).toBe(false)
      expect(notice.textContent).toMatch(/Checking for existing/i)

      settle(jsonResponse({ state: "clear", candidates: [] }))
    })

    // Focus belongs to whatever field staff are still typing in. A transient state that resolves on
    // its own must not yank it away.
    test("the checking state does not steal focus", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => new Promise(() => {}))
      const firstName = form.querySelector('[name="constituent[first_name]"]')
      firstName.focus()

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      expect(document.activeElement).toBe(firstName)
    })

    // A request that never settles used to leave the form in `checking` forever: Submit disabled,
    // four selected files that a reload would discard, and no way forward at all.
    test("a request that never settles times out and frees Submit", async () => {
      jest.useFakeTimers()
      jest.spyOn(global, "fetch").mockImplementation((_url, options) => new Promise((_resolve, reject) => {
        options.signal.addEventListener("abort", () => {
          const error = new Error("aborted")
          error.name = "AbortError"
          reject(error)
        })
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await Promise.resolve()
      jest.advanceTimersByTime(15000)
      jest.useRealTimers()
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("timed_out")
      expect(controller._identityReviewBlocksSubmit()).toBe(false)
      const notice = form.querySelector('[data-paper-application-target="identityReviewNotice"]')
      expect(notice.textContent).toMatch(/took too long/i)
    })

    // An ended session answers with a redirect to sign-in, which fetch reports as a successful HTML
    // response. Treated as a generic error it produced an unbreakable "submit again to retry" loop,
    // because retrying is exactly what does not work.
    test("an expired session is told apart from an ordinary failure", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => Promise.resolve({
        ok: true,
        redirected: true,
        headers: { get: () => "text/html" },
        json: () => Promise.reject(new Error("should not be called"))
      }))

      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
      await new Promise((resolve) => setTimeout(resolve, 0))

      const controller = controllerFor(application, form)
      expect(controller._identityReviewState).toBe("session_expired")
      const notice = form.querySelector('[data-paper-application-target="identityReviewNotice"]')
      expect(notice.textContent).toMatch(/another browser tab/i)
      // The advice is only truthful if the page really is preserved, so nothing may be submitted.
      expect(form.requestSubmit).not.toHaveBeenCalled()
    })

    // Candidate selection has to be single-flight and cancellable. These drive it through a
    // deferred picker so both properties are observable.
    describe("candidate selection", () => {
      let deferred
      let picker

      async function showCandidates() {
        jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({
          state: "needs_confirmation",
          candidates: [
            { id: 1, name: "First Candidate", selectable: true },
            { id: 2, name: "Second Candidate", selectable: true }
          ],
          reasons: ["name_dob"],
          token: "v1:1:abc"
        }))
        form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))
        await new Promise((resolve) => setTimeout(resolve, 0))
      }

      beforeEach(() => {
        deferred = {}
        deferred.promise = new Promise((resolve) => { deferred.resolve = resolve })
        picker = { selectAdultFromIdentityReview: jest.fn(() => deferred.promise) }

        const host = document.createElement("div")
        host.setAttribute("data-controller", "adult-picker")
        form.appendChild(host)
        // Stimulus exposes `application` as a getter, so it is defined rather than assigned.
        Object.defineProperty(controllerFor(application, form), 'application', {
          value: { getControllerForElementAndIdentifier: () => picker },
          configurable: true
        })
      })

      test("two quick clicks invoke the picker once and keep the buttons disabled", async () => {
        await showCandidates()
        const buttons = form.querySelectorAll('[data-paper-application-target="identityReviewCandidates"] button')

        buttons[0].click()
        buttons[1].click()
        await Promise.resolve()

        expect(picker.selectAdultFromIdentityReview).toHaveBeenCalledTimes(1)
        expect([...buttons].every((button) => button.disabled)).toBe(true)

        deferred.resolve({ selected: false, reason: "not eligible" })
        await new Promise((resolve) => setTimeout(resolve, 0))
        expect([...buttons].every((button) => !button.disabled)).toBe(true)
      })

      test("buttons are restored when the check fails", async () => {
        await showCandidates()
        const button = form.querySelector('[data-paper-application-target="identityReviewCandidates"] button')

        button.click()
        await Promise.resolve()
        expect(button.disabled).toBe(true)

        deferred.resolve(undefined)
        await new Promise((resolve) => setTimeout(resolve, 0))
        expect(button.disabled).toBe(false)
      })

      // Editing the applicant while eligibility is loading must cancel it: otherwise the answer
      // arrives afterwards and selects a candidate for an identity no longer on screen.
      test("editing the identity while a selection is pending cancels it", async () => {
        await showCandidates()
        const button = form.querySelector('[data-paper-application-target="identityReviewCandidates"] button')
        button.click()
        await Promise.resolve()

        const field = form.querySelector('[name="constituent[first_name]"]')
        field.value = "Someone Different"
        field.dispatchEvent(new Event("input", { bubbles: true }))

        const signal = picker.selectAdultFromIdentityReview.mock.calls[0][1].signal
        expect(signal.aborted).toBe(true)

        deferred.resolve({ selected: true })
        await new Promise((resolve) => setTimeout(resolve, 0))
        expect(controllerFor(application, form)._identityReviewState).toBe("idle")
      })
    })

    test("disconnect clears the in-flight request and the expiry timer", async () => {
      jest.spyOn(global, "fetch").mockImplementation(() => jsonResponse({ state: "clear", candidates: [] }))
      const controller = controllerFor(application, form)
      form.dispatchEvent(new Event("submit", { cancelable: true, bubbles: true }))

      controller.disconnect()

      expect(controller._identityReviewAbort).toBeNull()
      expect(controller._identityReviewTimer).toBeNull()
    })
  })

  describe("when the branch does not create a new self applicant", () => {
    test("selecting an existing constituent submits without a review", async () => {
      form = buildForm({ existingConstituentId: "42" })
      application = await startApplication()
      const fetchMock = jest.spyOn(global, "fetch")

      const event = new Event("submit", { cancelable: true, bubbles: true })
      form.dispatchEvent(event)

      expect(fetchMock).not.toHaveBeenCalled()
      expect(event.defaultPrevented).toBe(false)
    })

    test("a dependent application submits without a review", async () => {
      form = buildForm({ applicantType: "dependent" })
      application = await startApplication()
      const fetchMock = jest.spyOn(global, "fetch")

      const event = new Event("submit", { cancelable: true, bubbles: true })
      form.dispatchEvent(event)

      expect(fetchMock).not.toHaveBeenCalled()
      expect(event.defaultPrevented).toBe(false)
    })
  })
})
