import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

// Submits the W9 review form as approved, or as rejected once a reason code and explanation are given.
class W9ReviewController extends Controller {
  static targets = ["form", "status", "rejectionReason", "approveButton", "rejectButton"]


  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("W9 Review controller connected")
    }
  }

  approve() {
    if (!this.hasStatusTarget || !this.hasFormTarget) {
      return;
    }

    this.statusTarget.value = 'approved'
    this.formTarget.requestSubmit()
  }

  reject() {
    if (!this.hasRejectionReasonTarget || !this.hasRejectButtonTarget || !this.hasStatusTarget || !this.hasFormTarget) {
      return;
    }

    // The first click reveals the rejection fields; the second submits.
    const isHidden = this.rejectionReasonTarget.classList.contains('hidden')
    
    if (isHidden) {
      setVisible(this.rejectionReasonTarget, true)
      this.rejectButtonTarget.textContent = 'Confirm Reject'
      const firstRadio = this.rejectionReasonTarget.querySelector('input[type="radio"]')
      if (firstRadio) { firstRadio.focus() }
    } else {
      const reasonCodeSelected = Array.from(
        this.rejectionReasonTarget.querySelectorAll('input[name="w9_review[rejection_reason_code]"]')
      ).some(radio => radio.checked)
      
      const reasonText = this.rejectionReasonTarget.querySelector('#w9_review_rejection_reason')?.value.trim() || ''
      
      if (!reasonCodeSelected || reasonText === '') {
        const errorMessage = 'Please select a rejection reason and provide a detailed explanation.'
        console.error(errorMessage)
        alert(errorMessage)
      } else {
        this.statusTarget.value = 'rejected'
        this.formTarget.requestSubmit()
      }
    }
  }
}


export default W9ReviewController
