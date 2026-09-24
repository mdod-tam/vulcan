import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"

class RoleSelectController extends Controller {
  static targets = ["select", "capability"]

  static values = {
    userId: String,
    updateRoleUrl: String,
    updateCapabilitiesUrl: String
  }

  connect() {
    // Request key for tracking
    this.requestKey = `role-select-${this.identifier}-${Date.now()}`
  }

  disconnect() {
    // Cancel any pending requests
    railsRequest.cancel(this.requestKey)
  }

  roleChanged(event) {
    const data = { role: event.target.value }

    this.saveChanges('role', data)
  }

  toggleCapability(event) {
    const data = {
      capability: event.target.dataset.capability,
      enabled: event.target.checked
    }

    // Store reference for potential revert on error
    this.lastToggleData = {
      element: event.target,
      capability: data.capability,
      previousState: !data.enabled
    }

    this.saveChanges('capability', data)
  }

  // Rails 8 request with centralized service
  async saveChanges(changeType, data) {
    // Use Stimulus values for URLs instead of hardcoded paths
    const url = changeType === 'role' ? this.updateRoleUrlValue : this.updateCapabilitiesUrlValue

    try {
      // Use centralized rails request service
      const result = await railsRequest.perform({
        method: 'patch',
        url: url,
        body: data,
        key: this.requestKey
      })

      if (result.success) {
        // Reload to show the server-rendered role and capability state.
        window.location.reload()
      }
    } catch (error) {
      console.error("Rails 8 request failed", {
        error: error,
        message: error.message,
        changeType: changeType,
        data: data
      })

      // Revert UI changes on error (for capability toggles)
      if (changeType === 'capability' && this.lastToggleData) {
        const { element, previousState } = this.lastToggleData
        if (element) {
          element.checked = previousState
        }
      }
    }
  }
}

export default RoleSelectController
