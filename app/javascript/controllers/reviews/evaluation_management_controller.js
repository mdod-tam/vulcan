import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

class EvaluationManagementController extends Controller {
  static targets = [
    "statusSelect", 
    "completionFields",
    "rescheduleSection"
  ]

  connect() {
    this.toggleFieldsBasedOnStatus()
  }

  toggleFieldsBasedOnStatus() {
    if (!this.hasStatusSelectTarget) {
      return;
    }

    const selectedStatus = this.statusSelectTarget.value

    if (this.hasCompletionFieldsTarget) {
      const target = this.completionFieldsTarget
      const isCompleted = selectedStatus === "completed"
      
      // Use setVisible utility for consistent visibility management
      setVisible(target, isCompleted)
      
      // Set required attributes using the utility
      this.setRequiredAttributes(isCompleted)
    }
  }

  setRequiredAttributes(required) {
    if (this.hasCompletionFieldsTarget) {
      const target = this.completionFieldsTarget
      target.querySelectorAll("[data-completion-required]").forEach(element => {
        // Use setVisible utility's required option for consistency
        setVisible(element, true, { required })
      })
    }
  }
}

// Apply target safety mixin

export default EvaluationManagementController
