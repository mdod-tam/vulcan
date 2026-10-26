import { Application } from "@hotwired/stimulus"
import EmailPreviewController from "../../../app/javascript/controllers/admin/email_preview_controller"

describe("EmailPreviewController", () => {
  let application, frame, alert

  beforeEach(async () => {
    document.body.innerHTML = `
      <form data-controller="email-preview" data-action="message@window->email-preview#receive submit->email-preview#start">
        <div role="alert" data-email-preview-target="error" hidden></div>
        <iframe data-email-preview-target="document"></iframe>
      </form>`
    application = Application.start()
    application.register("email-preview", EmailPreviewController)
    await Promise.resolve()
    frame = document.querySelector("iframe")
    alert = document.querySelector('[role="alert"]')
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
  })

  function message(overrides = {}) {
    window.dispatchEvent(new MessageEvent("message", {
      source: frame.contentWindow,
      origin: "null",
      data: { type: "mat-vulcan:email-preview", failed: true },
      ...overrides
    }))
  }

  test("announces only its own opaque preview's boolean result and clears a corrected draft", () => {
    message({ source: window })
    message({ origin: "https://example.test" })
    message({ data: { type: "other", failed: true } })
    message({ data: { type: "mat-vulcan:email-preview", failed: "true" } })
    expect(alert.hidden).toBe(true)
    expect(alert.textContent).toBe("")

    message()
    expect(alert.hidden).toBe(false)
    expect(alert.textContent).toMatch(/Preview unavailable.*correct the draft/)
    message({ data: { type: "mat-vulcan:email-preview", failed: false } })
    expect(alert.hidden).toBe(true)
    expect(alert.textContent).toBe("")
  })

  test("empties the live region before an unchanged invalid retry", () => {
    message()
    document.querySelector("form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    expect(alert.hidden).toBe(true)
    expect(alert.textContent).toBe("")
    message()
    expect(alert.hidden).toBe(false)
    expect(alert.textContent).toMatch(/Preview unavailable/)
  })
})
