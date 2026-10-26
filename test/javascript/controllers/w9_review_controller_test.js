import { Application } from "@hotwired/stimulus"
import W9ReviewController from "controllers/reviews/w9_review_controller"

describe("W9 review submission", () => {
  let application, form, approve, reject, reason, code, nativeSubmit, requestSubmit

  beforeEach(async () => {
    document.body.innerHTML = `<div data-controller="w9-review">
      <form method="post" data-w9-review-target="form">
        <input type="hidden" name="w9_review[status]" data-w9-review-target="status">
        <div class="hidden" data-w9-review-target="rejectionReason">
          <input type="radio" name="w9_review[rejection_reason_code]" value="other">
          <textarea id="w9_review_rejection_reason" name="w9_review[rejection_reason]"></textarea>
        </div>
        <button type="button" data-w9-review-target="approveButton" data-action="w9-review#approve">Approve</button>
        <button type="button" data-w9-review-target="rejectButton" data-action="w9-review#reject">Reject</button>
      </form>
    </div>`
    application = Application.start()
    application.register("w9-review", W9ReviewController)
    await Promise.resolve()
    await Promise.resolve()
    form = document.querySelector("form")
    approve = form.querySelector('[data-w9-review-target="approveButton"]')
    reject = form.querySelector('[data-w9-review-target="rejectButton"]')
    reason = form.querySelector("textarea")
    code = form.querySelector('[type="radio"]')
    nativeSubmit = jest.spyOn(form, "submit").mockImplementation(() => {})
    requestSubmit = jest.spyOn(form, "requestSubmit")
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    jest.restoreAllMocks()
  })

  const prepare = decision => {
    if (decision === "rejected") {
      reject.click()
      code.checked = true
      reason.value = "Unfinished W9 rejection"
    }
  }
  const choose = decision => (decision === "approved" ? approve : reject).click()

  test.each(["approved", "rejected"])("%s decision uses native submit events so the expiry guard can intercept", decision => {
    prepare(decision)
    const onSubmit = jest.fn(event => event.preventDefault())
    form.addEventListener("submit", onSubmit)
    choose(decision)

    expect(requestSubmit).toHaveBeenCalledWith()
    expect(nativeSubmit).not.toHaveBeenCalled()
    expect(onSubmit).toHaveBeenCalledTimes(1)
    expect(form.querySelector('[name="w9_review[status]"]').value).toBe(decision)
    if (decision === "rejected") expect(reason.value).toBe("Unfinished W9 rejection")
  })

  test.each(["approved", "rejected"])("%s decision respects native form validity before dispatching submit", decision => {
    prepare(decision)
    reason.setCustomValidity("Review this explanation")
    const onInvalid = jest.fn()
    const onSubmit = jest.fn(event => event.preventDefault())
    form.addEventListener("invalid", onInvalid, true)
    form.addEventListener("submit", onSubmit)
    choose(decision)

    expect(onInvalid).toHaveBeenCalledTimes(1)
    expect(onSubmit).not.toHaveBeenCalled()
    expect(nativeSubmit).not.toHaveBeenCalled()
  })

  test("rejection still requires its reason code and explanation before requesting submission", () => {
    jest.spyOn(window, "alert").mockImplementation(() => {})
    reject.click()
    reject.click()
    expect(requestSubmit).not.toHaveBeenCalled()
    expect(nativeSubmit).not.toHaveBeenCalled()
    expect(window.alert).toHaveBeenCalledTimes(1)
  })
})
