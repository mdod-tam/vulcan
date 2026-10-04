import { Application } from "@hotwired/stimulus"
import VisibilityController from "controllers/ui/visibility_controller"

describe("VisibilityController", () => {
  let application
  let controller
  let element
  let passwordField
  let confirmationField
  let toggleButton
  let confirmationToggleButton
  let statusElement
  
  beforeEach(() => {
    document.body.innerHTML = `
      <div data-controller="visibility">
        <div class="relative">
          <input type="password" id="password" data-visibility-target="field" />
          <button type="button" data-action="click->visibility#togglePassword">Toggle</button>
        </div>
        <div class="relative">
          <input type="password" id="confirmation" data-visibility-target="fieldConfirmation" />
          <button type="button" data-action="click->visibility#togglePassword">Toggle Confirmation</button>
        </div>
        <div id="status" data-visibility-target="status"></div>
        <div class="relative">
          <input type="password" id="no-targets-field" />
          <button type="button" data-action="click->visibility#togglePassword">No Targets Toggle</button>
        </div>
      </div>
    `
    
    application = Application.start()
    application.register("visibility", VisibilityController)
    
    controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="visibility"]'),
      "visibility"
    )
    
    element = document.querySelector("[data-controller='visibility']")
    passwordField = element.querySelector("#password")
    confirmationField = element.querySelector("#confirmation")
    toggleButton = element.querySelector("button[data-action*='togglePassword']")
    confirmationToggleButton = element.querySelectorAll("button[data-action*='togglePassword']")[1]
    statusElement = element.querySelector("#status")
    
    jest.useFakeTimers()
  })
  
  afterEach(() => {
    jest.useRealTimers()
    application.stop()
    document.body.innerHTML = ""
  })
  
  test("toggles password visibility when button is clicked", () => {
    const passwordField = document.getElementById("password")
    const toggleButton = document.querySelector('button[data-action*="togglePassword"]')
    
    expect(passwordField.type).toBe("password")
    
    toggleButton.click()
    
    expect(passwordField.type).toBe("text")
    expect(toggleButton.getAttribute("aria-pressed")).toBe("true")
    expect(toggleButton.getAttribute("aria-label")).toBe("Hide password")
    expect(toggleButton.classList.contains("eye-open")).toBe(true)
  })
  
  test("toggles confirmation password visibility when button is clicked", () => {
    const confirmationField = document.getElementById("confirmation")
    const confirmationToggleButton = document.querySelectorAll('button[data-action*="togglePassword"]')[1]
    
    expect(confirmationField.type).toBe("password")
    
    confirmationToggleButton.click()
    
    expect(confirmationField.type).toBe("text")
    expect(confirmationToggleButton.getAttribute("aria-pressed")).toBe("true")
    expect(confirmationToggleButton.getAttribute("aria-label")).toBe("Hide password")
    expect(confirmationToggleButton.classList.contains("eye-open")).toBe(true)
  })
  
  test("automatically hides password after timeout", () => {
    element.setAttribute("data-visibility-timeout-value", "5000")
    
    toggleButton.click()
    
    expect(passwordField.type).toBe("text")
    expect(statusElement.textContent.trim()).toBe("Password is visible")
    
    jest.advanceTimersByTime(5000)
    
    expect(passwordField.type).toBe("password")
    expect(toggleButton.getAttribute("aria-pressed")).toBe("false")
    expect(toggleButton.getAttribute("aria-label")).toBe("Show password")
    expect(toggleButton.classList.contains("eye-closed")).toBe(true)
    expect(statusElement.textContent.trim()).toBe("Password is hidden")
  })
  
  test("clears timeout when toggling back to hidden", () => {
    element.setAttribute("data-visibility-timeout-value", "5000")
    
    toggleButton.click()
    
    expect(passwordField.type).toBe("text")
    
    toggleButton.click()
    
    expect(passwordField.type).toBe("password")
    
    jest.advanceTimersByTime(5000)
    
    expect(passwordField.type).toBe("password")
  })
  
  test("does not throw when the password input is missing", () => {
    passwordField.remove()
    
    expect(() => {
      toggleButton.click()
    }).not.toThrow()
  })
  
  test("cleans up timeout on disconnect", () => {
    const originalClearTimeout = window.clearTimeout
    window.clearTimeout = jest.fn()
    
    element.setAttribute("data-visibility-timeout-value", "5000")
    toggleButton.click()
    
    application.controllers[0].disconnect()
    
    expect(window.clearTimeout).toHaveBeenCalled()
    
    window.clearTimeout = originalClearTimeout
  })
  
  test("toggles two password fields independently", () => {
    expect(passwordField.type).toBe("password")
    
    toggleButton.click()
    expect(passwordField.type).toBe("text")
    
    confirmationToggleButton.click()
    expect(confirmationField.type).toBe("text")
    
    toggleButton.click()
    expect(passwordField.type).toBe("password")
    
    expect(confirmationField.type).toBe("text")
  })
  
  test("toggles an input without a field target", () => {
    const noTargetsField = document.getElementById("no-targets-field")
    const noTargetsButton = document.querySelectorAll('button[data-action*="togglePassword"]')[2]
    
    expect(noTargetsField.type).toBe("password")
    
    noTargetsButton.click()
    
    expect(noTargetsField.type).toBe("text")
    
    noTargetsButton.click()
    
    expect(noTargetsField.type).toBe("password")
  })
  
  test("updates status element when toggling", () => {
    const passwordField = document.getElementById("password")
    const toggleButton = document.querySelector('button[data-action*="togglePassword"]')
    const statusElement = document.getElementById("status")
    
    toggleButton.click()
    
    expect(statusElement.textContent).toBe("Password is visible")
    
    toggleButton.click()
    
    expect(statusElement.textContent).toBe("Password is hidden")
  })
})
