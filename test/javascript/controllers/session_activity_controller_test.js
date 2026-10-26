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
      data-session-activity-sign-out-url-value="/sign_out"
      data-session-activity-state-value='${JSON.stringify(initial)}'
      data-session-activity-messages-value="${JSON.stringify(messages[locale]).replaceAll('"', '&quot;')}"
      data-action="input@document->session-activity#recordInteraction change@document->session-activity#recordInteraction keydown@document->session-activity#recordInteraction pointerdown@document->session-activity#recordInteraction submit@document->session-activity#beforeSubmit:capture">
      <p class="sr-only" role="status" aria-live="polite" aria-atomic="true" data-session-activity-target="status"></p>
      <aside hidden data-session-activity-target="notice" tabindex="-1">
        <p data-session-activity-target="message"></p>
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

  test("the mounted live region stays exposed and updates only when the countdown changes", async () => {
    await render()
    const status = document.querySelector('[role="status"]')
    expect(status.closest("[hidden]")).toBeNull()
    expect(status).toBeEmptyDOMElement()
    expect(controller.noticeTarget.hidden).toBe(true)

    jest.advanceTimersByTime(26 * minute)
    await flush()
    expect(document.querySelector('[role="status"]')).toBe(status)
    expect(status.textContent).toBe(messages.en.idle_other.replace("%{minutes}", "4"))
    const changed = jest.fn()
    const observer = new MutationObserver(changed)
    observer.observe(status, { childList: true })
    jest.advanceTimersByTime(2000)
    await flush()
    expect(changed).not.toHaveBeenCalled()
    observer.disconnect()

    controller.renewTarget.click()
    await flush()
    expect(status).toBeEmptyDOMElement()
    expect(status.closest("[hidden]")).toBeNull()
    expect(controller.noticeTarget.hidden).toBe(true)
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

  test("expired modal POST outside main keeps the draft and focuses an in-dialog notice", async () => {
    await render({ idle: 1, locale: "es" })
    document.body.insertAdjacentHTML("beforeend", `<dialog open><form method="post" action="/admin/applications/1">
      <textarea name="rejection_reason">Unfinished rejection</textarea><button>Save</button>
    </form></dialog>`)
    const dialog = document.querySelector("dialog")
    const form = dialog.querySelector("form")
    const laterSubmit = jest.fn()
    document.addEventListener("submit", laterSubmit)
    jest.advanceTimersByTime(minute)

    expect(form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(false)
    expect(laterSubmit).not.toHaveBeenCalled()
    expect(dialog.open).toBe(true)
    expect(form.querySelector("textarea").value).toBe("Unfinished rejection")
    const notice = dialog.querySelector('[role="alert"]')
    expect(notice).toBeVisible()
    expect(notice.textContent).toBe(messages.es.expired)
    expect(document.activeElement).toBe(notice)
    expect(notice.querySelector("button")).toBeNull()
    expect(form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(false)
    expect(dialog.querySelectorAll('[role="alert"]')).toHaveLength(1)
    expect(posts()).toHaveLength(0)
    document.removeEventListener("submit", laterSubmit)
  })

  test("an active session allows a modal POST outside main", async () => {
    await render()
    document.body.insertAdjacentHTML("beforeend", '<dialog open><form method="post"><button>Save</button></form></dialog>')
    expect(document.querySelector("dialog form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(true)
    expect(document.querySelector('dialog [role="alert"]')).toBeNull()
  })

  test.each(["form", "turbo-frame"])("expiry blocks submission before a %s handler can send or intercept it", async selector => {
    await render({ idle: 1 })
    document.body.insertAdjacentHTML("beforeend", '<turbo-frame><form method="post"><input value="Unfinished draft"><button>Save</button></form></turbo-frame>')
    const form = document.querySelector("turbo-frame form")
    const send = jest.fn(event => {
      event.preventDefault()
      event.stopImmediatePropagation()
    })
    const handlerTarget = selector === "form" ? form : form.parentElement
    handlerTarget.addEventListener("submit", send)
    jest.advanceTimersByTime(minute)

    expect(form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(false)
    expect(send).not.toHaveBeenCalled()
    expect(form.querySelector("input").value).toBe("Unfinished draft")
    expect(document.activeElement).toBe(controller.noticeTarget)
  })

  test("an active session still reaches custom form and Turbo frame submit handlers", async () => {
    await render()
    document.body.insertAdjacentHTML("beforeend", '<turbo-frame><form method="post"><button>Save</button></form></turbo-frame>')
    const form = document.querySelector("turbo-frame form")
    const onForm = jest.fn()
    const onFrame = jest.fn(event => event.preventDefault())
    form.addEventListener("submit", onForm)
    form.parentElement.addEventListener("submit", onFrame)

    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    expect(onForm).toHaveBeenCalledTimes(1)
    expect(onFrame).toHaveBeenCalledTimes(1)
    expect(controller.noticeTarget.hidden).toBe(true)
  })

  test("a fresh server deadline clears the modal's derived expiry notice", async () => {
    await render({ idle: 1 })
    document.body.insertAdjacentHTML("beforeend", '<dialog open><form method="post"><button>Save</button></form></dialog>')
    const form = document.querySelector("dialog form")
    jest.advanceTimersByTime(minute)
    form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    expect(document.querySelector('dialog [role="alert"]')).toBeVisible()

    controller.setDeadlines(state())
    expect(document.querySelector('dialog [role="alert"]')).not.toBeVisible()
    expect(form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(true)
  })

  test("timer ticks do not repeatedly announce an unchanged modal expiry message", async () => {
    await render({ idle: 1 })
    document.body.insertAdjacentHTML("beforeend", '<dialog open><form method="post"><button>Save</button></form></dialog>')
    jest.advanceTimersByTime(minute)
    document.querySelector("dialog form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
    const changed = jest.fn()
    const observer = new MutationObserver(changed)
    observer.observe(document.querySelector('dialog [role="alert"]'), { childList: true })
    jest.advanceTimersByTime(2000)
    await flush()
    expect(changed).not.toHaveBeenCalled()
    observer.disconnect()
  })

  test.each(["get", "dialog"])("expiry permits a %s form and submitter override", async method => {
    await render({ idle: 1 })
    document.querySelector("main").innerHTML = `<form method="${method}"><button>Continue</button></form>
      <form method="post"><button formmethod="${method}">Continue</button></form>`
    jest.advanceTimersByTime(minute)
    document.querySelectorAll("main form").forEach(form => {
      const event = new Event("submit", { bubbles: true, cancelable: true })
      Object.defineProperty(event, "submitter", { value: form.querySelector("button") })
      expect(form.dispatchEvent(event)).toBe(true)
    })
  })

  test.each([
    ["/sign_out", "delete", true],
    ["/sign_out", "post", false],
    ["/admin/users/1", "delete", false],
    ["https://elsewhere.example/sign_out", "delete", false]
  ])("expiry permits only explicit same-origin sign-out: %s %s", async (action, override, allowed) => {
    await render({ idle: 1 })
    document.body.insertAdjacentHTML("beforeend", `<form id="header-action" method="post" action="${action}">
      <input type="hidden" name="_method" value="${override}"><button>Submit</button></form>`)
    jest.advanceTimersByTime(minute)
    const form = document.getElementById("header-action")
    expect(form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))).toBe(allowed)
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
