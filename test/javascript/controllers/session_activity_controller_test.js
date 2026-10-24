import { Application } from "@hotwired/stimulus"
import SessionActivityController from "controllers/auth/session_activity_controller"
import { railsRequest } from "services/rails_request"

jest.mock("services/rails_request", () => ({ railsRequest: { perform: jest.fn() } }))

const minute = 60_000
const posts = () => railsRequest.perform.mock.calls.filter(([options]) => options.method === "post")
const flush = async () => { await Promise.resolve(); await Promise.resolve() }
const messages = {
  en: {
    expired: "Your session expired. Keep this page open and copy any unfinished work before signing in again.",
    absolute: "Your sign-in expires soon. Save your work before signing in again.",
    refresh_failed: "We couldn't refresh your session. Check your connection, then choose Keep working.",
    idle_one: "Your session expires in %{minutes} minute. Choose Keep working to stay signed in.",
    idle_other: "Your session expires in %{minutes} minutes. Choose Keep working to stay signed in."
  },
  es: {
    expired: "Su sesión ha expirado. Mantenga esta página abierta y copie el trabajo pendiente antes de volver a iniciar sesión.",
    absolute: "Su sesión está por expirar. Guarde su trabajo antes de volver a iniciar sesión.",
    refresh_failed: "No pudimos renovar su sesión. Revise su conexión y seleccione Seguir trabajando.",
    idle_one: "Su sesión vence en %{minutes} minuto. Seleccione Seguir trabajando para mantener la sesión iniciada.",
    idle_other: "Su sesión vence en %{minutes} minutos. Seleccione Seguir trabajando para mantener la sesión iniciada."
  }
}

describe("signed-in form session activity", () => {
  let application, controller, host, serverDeadlines
  const state = ({ idle = 30, absolute = 24 * 60 } = {}) => ({
    idle_expires_at: new Date(Date.now() + idle * minute).toISOString(),
    absolute_expires_at: new Date(Date.now() + absolute * minute).toISOString(),
    issued_at: new Date().toISOString()
  })

  const render = async ({ idle = 30, absolute = 24 * 60, locale = "en" } = {}) => {
    const initial = state({ idle, absolute })
    serverDeadlines = initial
    document.body.innerHTML = `<div data-controller="session-activity"
      data-session-activity-url-value="/session_activity"
      data-session-activity-state-value='${JSON.stringify(initial)}'
      data-session-activity-messages-value="${JSON.stringify(messages[locale]).replaceAll('"', '&quot;')}"
      data-action="input@document->session-activity#recordInteraction change@document->session-activity#recordInteraction keydown@document->session-activity#recordInteraction pointerdown@document->session-activity#recordInteraction submit@document->session-activity#beforeSubmit">
      <aside hidden data-session-activity-target="notice" tabindex="-1">
        <p role="status" data-session-activity-target="message"></p>
        <button type="button" data-session-activity-target="renew" data-action="session-activity#renew">${locale === "es" ? "Seguir trabajando" : "Keep working"}</button>
      </aside>
    </div><main><form method="post"><input name="first_name" value="Unfinished work"><button>Submit</button></form></main>`
    application = Application.start()
    application.register("session-activity", SessionActivityController)
    await flush()
    host = document.querySelector('[data-controller="session-activity"]')
    controller = application.getControllerForElementAndIdentifier(host, "session-activity")
  }

  beforeEach(() => {
    jest.useFakeTimers()
    jest.setSystemTime(new Date("2026-10-23T12:00:00Z"))
    railsRequest.perform.mockReset()
    railsRequest.perform.mockImplementation(async ({ method }) => {
      if (method === "post") serverDeadlines.idle_expires_at = new Date(Date.now() + 30 * minute).toISOString()
      return { data: { ...serverDeadlines, issued_at: new Date().toISOString() } }
    })
  })

  afterEach(async () => {
    application?.stop()
    await flush()
    document.body.innerHTML = ""
    jest.useRealTimers()
  })

  test("timers and synthetic input never renew a session", async () => {
    await render()
    jest.advanceTimersByTime(26 * minute)
    document.querySelector("input").dispatchEvent(new Event("input", { bubbles: true }))
    await flush()
    expect(posts()).toHaveLength(0)
    expect(controller.noticeTarget.hidden).toBe(false)
    expect(controller.messageTarget.textContent).toContain("Your session expires in 4 minutes")
  })

  test("genuine visible interactions renew no more than once a minute", async () => {
    await render()
    jest.advanceTimersByTime(2 * minute)
    controller.recordInteraction({ isTrusted: true })
    await flush()
    expect(posts()).toHaveLength(1)
    expect(railsRequest.perform).toHaveBeenCalledWith({ method: "post", url: "/session_activity", headers: { Accept: "application/json" } })
    controller.recordInteraction({ isTrusted: true })
    jest.advanceTimersByTime(minute - 1)
    controller.recordInteraction({ isTrusted: true })
    await flush()
    expect(posts()).toHaveLength(1)
    jest.advanceTimersByTime(1)
    controller.recordInteraction({ isTrusted: true })
    await flush()
    expect(posts()).toHaveLength(2)
  })

  test("hidden tabs do not refresh activity", async () => {
    await render()
    jest.advanceTimersByTime(minute)
    const hidden = jest.spyOn(document, "hidden", "get").mockReturnValue(true)
    controller.recordInteraction({ isTrusted: true })
    await flush()
    expect(posts()).toHaveLength(0)
    hidden.mockRestore()
  })

  test("a status check notices activity from another tab without posting activity", async () => {
    await render({ idle: 4 })
    expect(controller.noticeTarget.hidden).toBe(false)
    jest.advanceTimersByTime(2 * minute)
    await flush()
    serverDeadlines.idle_expires_at = new Date(Date.now() + 30 * minute).toISOString()
    controller.checkStatus()
    await flush()
    expect(controller.noticeTarget.hidden).toBe(true)
    expect(posts()).toHaveLength(0)
  })

  test("Keep working refreshes the idle warning while preserving field values", async () => {
    await render({ idle: 4 })
    expect(controller.noticeTarget.hidden).toBe(false)
    controller.renewTarget.click()
    await flush()
    expect(posts()).toHaveLength(1)
    expect(controller.noticeTarget.hidden).toBe(true)
    expect(document.querySelector("input").value).toBe("Unfinished work")
  })

  test("absolute expiry warns to save rather than offering an extension", async () => {
    await render({ absolute: 4 })
    expect(controller.messageTarget.textContent).toContain("Save your work")
    expect(controller.renewTarget.hidden).toBe(true)
  })

  test("expired state preserves the page and stops a form POST", async () => {
    await render({ idle: 1 })
    jest.advanceTimersByTime(minute)
    const form = document.querySelector("main form")
    const event = new Event("submit", { bubbles: true, cancelable: true })
    expect(form.dispatchEvent(event)).toBe(false)
    expect(controller.messageTarget.textContent).toContain("Your session expired")
    expect(document.querySelector("input").value).toBe("Unfinished work")
    expect(posts()).toHaveLength(0)
  })

  test("401 leaves an honest expired state instead of treating sign-in as success", async () => {
    await render({ idle: 4 })
    railsRequest.perform.mockRejectedValueOnce(Object.assign(new Error("authentication_required"), { status: 401 }))
    controller.renewTarget.click()
    await flush()
    expect(controller.messageTarget.textContent).toContain("Your session expired")
    expect(controller.renewTarget.hidden).toBe(true)
    expect(document.querySelector("input").value).toBe("Unfinished work")
  })

  test("network errors offer an explicit retry without clearing the form", async () => {
    await render({ idle: 4 })
    railsRequest.perform.mockRejectedValueOnce(new TypeError("network unavailable"))
    controller.renewTarget.click()
    await flush()
    expect(controller.messageTarget.textContent).toContain("Keep working")
    expect(controller.renewTarget.hidden).toBe(false)
    expect(controller.renewTarget.disabled).toBe(false)
    controller.renewTarget.click()
    await flush()
    expect(controller.noticeTarget.hidden).toBe(true)
    expect(document.querySelector("input").value).toBe("Unfinished work")
  })

  test("Spanish countdown uses server-provided singular and plural text without renewing in the background", async () => {
    await render({ idle: 4, locale: "es" })
    expect(controller.messageTarget.textContent).toBe(messages.es.idle_other.replace("%{minutes}", "4"))
    jest.advanceTimersByTime(3 * minute)
    await flush()
    expect(controller.messageTarget.textContent).toBe(messages.es.idle_one.replace("%{minutes}", "1"))
    expect(controller.renewTarget.textContent).toBe("Seguir trabajando")
    expect(posts()).toHaveLength(0)
    controller.renewTarget.click()
    await flush()
    expect(controller.noticeTarget.hidden).toBe(true)
    expect(document.querySelector("input").value).toBe("Unfinished work")
  })

  test("Spanish absolute expiry and failed refresh messages remain localized", async () => {
    await render({ idle: 4, locale: "es" })
    railsRequest.perform.mockRejectedValueOnce(new TypeError("offline"))
    controller.renewTarget.click()
    await flush()
    expect(controller.messageTarget.textContent).toBe(messages.es.refresh_failed)
    controller.absoluteDeadline = Date.now() + 4 * minute
    controller.updateNotice()
    expect(controller.messageTarget.textContent).toBe(messages.es.absolute)
    expect(controller.renewTarget.hidden).toBe(true)
  })

  test("Spanish expiry preserves the form and announces the localized next step", async () => {
    await render({ idle: 1, locale: "es" })
    jest.advanceTimersByTime(minute)
    await flush()
    const event = new Event("submit", { bubbles: true, cancelable: true })
    expect(document.querySelector("main form").dispatchEvent(event)).toBe(false)
    expect(controller.messageTarget.textContent).toBe(messages.es.expired)
    expect(document.querySelector("input").value).toBe("Unfinished work")
    expect(posts()).toHaveLength(0)
  })
})
