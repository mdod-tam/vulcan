import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

// Shows the custom date range fields when "Custom Range" is selected in the date range dropdown.
class DateRangeController extends Controller {
  static targets = ["customRange"]

  connect() {
    const picker = this.element.querySelector('[name="period"], [name="date_range"]')
    if (picker) {
      this.toggleCustomRange({ target: picker })
    }
  }

  toggleCustomRange(event) {
    const selectElement = event.target
    const isCustomRange = selectElement && selectElement.value === "custom"

    if (!this.hasCustomRangeTarget) {
      return;
    }

    this.customRangeTargets.forEach(element => {
      setVisible(element, isCustomRange)
    })
  }
}


export default DateRangeController
