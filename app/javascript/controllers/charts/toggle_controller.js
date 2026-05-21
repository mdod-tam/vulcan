import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["chart", "button"]

  connect() {
    // Guard against missing targets
    if (!this.hasChartTarget || !this.hasButtonTarget) return
    
    // Initialize button state
    this.buttonTarget.setAttribute('aria-expanded', 'false')
    
    // Use the chart's actual ID if it exists, otherwise skip aria-controls
    if (this.chartTarget.id) {
      this.buttonTarget.setAttribute('aria-controls', this.chartTarget.id)
    }
  }

  toggle() {
    // Guard against missing targets
    if (!this.hasChartTarget) return
    
    const isHidden = this.chartTarget.classList.contains('hidden')
    setVisible(this.chartTarget, isHidden)
    
    // Update button state for accessibility
    if (this.hasButtonTarget) {
      this.buttonTarget.setAttribute('aria-expanded', isHidden ? 'true' : 'false')
      this.buttonTarget.textContent = isHidden ? 'Hide Chart' : 'Show Chart'
    }

    if (isHidden) {
      this.chartTarget.querySelectorAll('[data-controller~="chart"]').forEach((el) => {
        el.dispatchEvent(new CustomEvent('visibility-changed', {
          bubbles: true,
          detail: { visible: true }
        }))
      })
    }
  }
}
