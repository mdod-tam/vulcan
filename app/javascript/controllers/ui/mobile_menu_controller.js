import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

class MobileMenuController extends Controller {
  static targets = [ "menu", "button" ]
  
  toggle() {
    // Use target safety to check for required targets
    if (!this.hasMenuTarget || !this.hasButtonTarget) {
      return;
    }
    
    const isCurrentlyHidden = this.menuTarget.classList.contains("hidden")
    setVisible(this.menuTarget, isCurrentlyHidden)
    
    const isExpanded = this.buttonTarget.getAttribute("aria-expanded") === "true"
    this.buttonTarget.setAttribute("aria-expanded", !isExpanded)
  }
}

// Apply target safety mixin

export default MobileMenuController
