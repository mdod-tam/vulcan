import { Controller } from "@hotwired/stimulus"

// Submits a user's access form through Turbo for each role or capability change. The server either applies the
// change or answers with a confirmation dialog, so this controller only builds the request and restores the
// controls when that dialog is dismissed.
class RoleSelectController extends Controller {
  static targets = ["select", "capability", "operation", "role", "capabilityField", "enabled"]

  static values = {
    userId: String,
    updateRoleUrl: String,
    updateCapabilitiesUrl: String,
    currentRole: String,
    // Set only for a vendor: leaving the vendor role clears vendor data, so the admin confirms first.
    conversionWarning: String
  }

  roleChanged(event) {
    const role = event.target.value

    if (this.conversionWarningValue && role !== this.currentRoleValue && !window.confirm(this.conversionWarningValue)) {
      event.target.value = this.currentRoleValue
      return
    }

    this.submit(this.updateRoleUrlValue, { role, capability: "", enabled: "" })
  }

  toggleCapability(event) {
    this.submit(this.updateCapabilitiesUrlValue, {
      role: "",
      capability: event.target.dataset.capability,
      enabled: event.target.checked
    })
  }

  submit(url, fields) {
    this.element.action = url
    this.operationTarget.value = this.newOperationId()
    this.roleTarget.value = fields.role
    this.capabilityFieldTarget.value = fields.capability
    this.enabledTarget.value = fields.enabled
    this.element.requestSubmit()
  }

  // Turbo marks the form busy for the whole request, so the controls cannot start a second change meanwhile.
  lock() {
    this.controls().forEach((control) => { control.disabled = true })
  }

  unlock() {
    this.controls().forEach((control) => { control.disabled = control.dataset.fromRole === "true" })
  }

  // The confirmation dialog for this user closed without applying the change.
  restore(event) {
    if (event.detail.dialog.dataset.userId === this.userIdValue) this.element.reset()
  }

  controls() {
    return [...this.selectTargets, ...this.capabilityTargets]
  }

  newOperationId() {
    return globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`
  }
}

export default RoleSelectController
