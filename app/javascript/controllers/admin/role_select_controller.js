// app/javascript/controllers/role_select_controller.js
import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"
import { applyTargetSafety } from "../../mixins/target_safety"

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
    
    if (process.env.NODE_ENV !== 'production') {
      console.log("RoleSelect Controller connected", {
        element: this.element,
        userId: this.userIdValue,
        updateRoleUrl: this.updateRoleUrlValue,
        updateCapabilitiesUrl: this.updateCapabilitiesUrlValue,
        hasSelectTarget: this.hasSelectTarget,
        hasCapabilityTargets: this.hasCapabilityTargets,
        targetsFound: {
          select: this.safeTarget('select', false),
          capabilities: this.safeTargets('capability', false)
        },

      })
    }
  }

  disconnect() {
    // Cancel any pending requests
    railsRequest.cancel(this.requestKey)
  }

  roleChanged(event) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Role changed triggered", {
        userId: this.userIdValue,
        newRole: event.target.value,
        element: event.target,
        currentTarget: event.currentTarget
      })
    }

    const data = { role: event.target.value }

    if (process.env.NODE_ENV !== 'production') {
      console.log("Sending role update with data:", data)
    }
    
    this.saveChanges('role', data)
  }

  toggleCapability(event) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Capability toggle triggered", {
        userId: this.userIdValue,
        capability: event.target.dataset.capability,
        checked: event.target.checked,
        element: event.target,
        currentTarget: event.currentTarget
      })
    }

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

    if (process.env.NODE_ENV !== 'production') {
      console.log("Sending capability update with data:", data)
    }
    
    this.saveChanges('capability', data)
  }

  // Rails 8 request with centralized service
  async saveChanges(changeType, data) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Starting Rails 8 request", {
        type: changeType,
        userId: this.userIdValue,
        data: data
      })
    }

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

      if (process.env.NODE_ENV !== 'production') {
        console.log("Rails 8 request completed", {
          success: result.success
        })
      }

      if (result.success) {
        const responseData = result.data
        
        if (process.env.NODE_ENV !== 'production') {
          console.log("Response data:", responseData)
        }

        // Success - server will handle flash message via Turbo Stream
        if (process.env.NODE_ENV !== 'production') {
          console.log("Role/capability change successful:", responseData.message || "Changes saved successfully")
        }
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

      // Error - log for debugging, server should handle error flash via Turbo Stream
      if (process.env.NODE_ENV !== 'production') {
        console.error("Role/capability change error:", error.message || "An error occurred")
      }
    }
  }
}

// Apply target safety mixin
applyTargetSafety(RoleSelectController)

export default RoleSelectController
