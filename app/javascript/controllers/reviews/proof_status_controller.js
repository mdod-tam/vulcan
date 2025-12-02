import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

// Handles showing/hiding proof upload and rejection sections based on status
class ProofStatusController extends Controller {
  static targets = ["uploadSection", "rejectionSection", "radioButtons"]

  connect() {
    // Initialize sections based on current selection with a small delay
    // to ensure the DOM is fully loaded and the radio button state is recognized
    this._initTimer = setTimeout(() => {
      const selectedStatus = this.getSelectedRadio();
      if (selectedStatus) {
        if (process.env.NODE_ENV !== 'production') {
          console.log('Initial status:', selectedStatus.value)
        }
        this.toggle({ target: selectedStatus })
      } else {
        // Fallback: If no radio is checked, default to showing upload section
        if (process.env.NODE_ENV !== 'production') {
          console.log('No radio checked, defaulting to upload section')
        }
        if (this.hasUploadSectionTarget) {
          setVisible(this.uploadSectionTarget, true);
        }
        if (this.hasRejectionSectionTarget) {
          setVisible(this.rejectionSectionTarget, false);
        }
      }
    }, 100) // Increased delay to ensure DOM is fully loaded
  }

  disconnect() {
    if (this._initTimer) {
      clearTimeout(this._initTimer);
    }
  }

  // Get the currently selected radio button using targets
  getSelectedRadio() {
    if (this.hasRadioButtonsTarget) {
      // radioButtonsTargets should contain all radio buttons
      const radios = this.radioButtonsTargets;
      return radios.find(radio => radio.checked) || null;
    }
    return null;
  }

  // Toggle sections based on status
  toggle(event) {
    // Check for both "approved" and "accepted" values to support both proofs and medical certifications
    const isApproved = event.target.value === "approved" || event.target.value === "accepted"
    
    if (process.env.NODE_ENV !== 'production') {
      console.log('Toggle called:', event.target.value, 'isApproved:', isApproved)
    }
    
    // Use setVisible utility for consistent visibility management
    if (this.hasUploadSectionTarget) {
      setVisible(this.uploadSectionTarget, isApproved);
    }
    if (this.hasRejectionSectionTarget) {
      setVisible(this.rejectionSectionTarget, !isApproved);
    }
  }
}

export default ProofStatusController
