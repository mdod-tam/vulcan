import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

// This controller handles the toggling of custom date range fields
// When "Custom Range" is selected in the date range dropdown
class DateRangeController extends Controller {
  static targets = ["customRange"]

  connect() {
    // Check if custom range is already selected on page load
    const picker = this.element.querySelector('[name="date_range"]')
    if (picker) {
      this.toggleCustomRange({ target: picker })
    }
  }

  toggleCustomRange(event) {
    const selectElement = event.target
    const isCustomRange = selectElement && selectElement.value === "custom"
    
    // Use target safety to check for required targets
    if (!this.hasCustomRangeTarget) {
      return;
    }
    
    // Use setVisible utility for consistent visibility management
    this.customRangeTargets.forEach(element => {
      setVisible(element, isCustomRange)
    })
  }
}

// Apply target safety mixin

export default DateRangeController
