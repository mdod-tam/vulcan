import { Application } from "@hotwired/stimulus"
import { waitFor } from "@testing-library/dom"
import * as WebAuthnJSON from "@github/webauthn-json"
import ReauthenticationController from "controllers/auth/reauthentication_controller"

jest.mock("@github/webauthn-json", () => ({ get: jest.fn() }))

let application, controller, form
const originalFetch = global.fetch

beforeEach(async () => {
  document.head.innerHTML = '<meta name="csrf-token" content="current-csrf">'
  document.body.innerHTML = `<form data-controller="reauthentication" data-reauthentication-options-url-value="/reauthentication/webauthn_options"
    data-reauthentication-sms-url-value="/reauthentication/sms_code" data-reauthentication-error-value="Please try again">
    <input name="password" value="secret-password" data-reauthentication-target="password" required>
    <select name="factor_type" data-reauthentication-target="factor"><option value="totp">App</option><option value="webauthn">Key</option><option value="sms">SMS</option></select>
    <div data-reauthentication-target="codeFields"><input name="code" data-reauthentication-target="code"></div>
    <div data-reauthentication-target="smsFields"><select name="credential_id"><option value="7">•••• 1234</option></select><button type="button">Send</button></div>
    <input name="credential" data-reauthentication-target="credential" type="hidden">
    <p data-reauthentication-target="feedback" tabindex="-1" role="status"></p>
    <input type="submit" data-reauthentication-target="submit">
  </form>`
  application = Application.start()
  application.register("reauthentication", ReauthenticationController)
  await waitFor(() => expect(application.controllers).toHaveLength(1))
  form = document.querySelector("form")
  controller = application.controllers[0]
  global.fetch = jest.fn()
  WebAuthnJSON.get.mockReset()
})

afterEach(() => {
  application.stop()
  document.body.innerHTML = ""
  document.head.innerHTML = ""
  global.fetch = originalFetch
  jest.restoreAllMocks()
})

test("changing method removes hidden code requirements and discards previous assertions", () => {
  controller.codeTarget.value = "123456"
  controller.credentialTarget.value = '{"id":"old-key"}'
  controller.factorTarget.value = "webauthn"
  controller.changeMethod()
  expect(controller.codeTarget).not.toBeRequired()
  expect(controller.codeFieldsTarget.hidden).toBe(true)
  expect(controller.credentialTarget.value).toBe("")
  controller.factorTarget.value = "sms"
  controller.changeMethod()
  expect(controller.codeTarget).toBeRequired()
  expect(controller.smsFieldsTarget.hidden).toBe(false)
  expect(controller.codeTarget.value).toBe("")
})

test("a refused key challenge restores submission and gives safe retry guidance", async () => {
  controller.factorTarget.value = "webauthn"
  controller.changeMethod()
  fetch.mockResolvedValue({ ok: false, status: 403 })
  await controller.submit({ preventDefault: jest.fn() })
  expect(controller.submitTarget).toBeEnabled()
  expect(controller.feedbackTarget).toHaveTextContent("Please try again")
  expect(WebAuthnJSON.get).not.toHaveBeenCalled()
  expect(controller.credentialTarget.value).toBe("")
})

test("key verification uses the requested challenge then returns to native form submission", async () => {
  controller.factorTarget.value = "webauthn"
  controller.changeMethod()
  fetch.mockResolvedValue({ ok: true, json: async () => ({ challenge: "new-challenge" }) })
  WebAuthnJSON.get.mockResolvedValue({ id: "verified-key" })
  const requestSubmit = jest.spyOn(form, "requestSubmit").mockImplementation(() => {})
  await controller.submit({ preventDefault: jest.fn() })
  expect(WebAuthnJSON.get).toHaveBeenCalledWith({ publicKey: { challenge: "new-challenge" } })
  expect(controller.credentialTarget.value).toBe('{"id":"verified-key"}')
  expect(requestSubmit).toHaveBeenCalledTimes(1)
  expect(fetch).toHaveBeenCalledWith("/reauthentication/webauthn_options", expect.objectContaining({
    method: "POST", headers: expect.objectContaining({ "X-CSRF-Token": "current-csrf" })
  }))
})

test("failed SMS delivery restores the button and does not advance verification", async () => {
  controller.factorTarget.value = "sms"
  controller.changeMethod()
  fetch.mockRejectedValue(new Error("private-provider-detail"))
  const button = controller.smsFieldsTarget.querySelector("button")
  await controller.sendSms({ currentTarget: button })
  expect(button).toBeEnabled()
  expect(controller.feedbackTarget).toHaveTextContent("Please try again")
  expect(controller.feedbackTarget).not.toHaveTextContent("private-provider-detail")
})
