import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = [
    "proofType",         // Hidden input for proof type 
    "reasonField",       // Text area for rejection reason
    "incomeOnlyReasons", // Income-specific rejection reasons container
    "medicalOnlyReasons", // Medical-specific rejection reasons container
    "generalReasons"     // General rejection reasons container (income/residency)
  ]

  static values = {
    // Income & Residency proof rejection reasons
    addressMismatchIncome: String,
    addressMismatchResidency: String,
    expiredIncome: String,
    expiredResidency: String,
    missingNameIncome: String,
    missingNameResidency: String,
    wrongDocumentIncome: String,
    wrongDocumentResidency: String,
    missingAmountIncome: String,
    exceedsThresholdIncome: String,
    outdatedSsAwardIncome: String,
    
    // Medical certification rejection reasons
    missingProviderCredentials: String,
    incompleteDisabilityDocumentation: String,
    outdatedCertification: String,
    missingSignature: String,
    missingFunctionalLimitations: String,
    incorrectFormUsed: String
  }

  connect() {
    // Clear form on connect and reset any error styling
    if (this.hasReasonFieldTarget) {
      this.reasonFieldTarget.value = ""
      this.reasonFieldTarget.classList.remove('border-red-500')
    }
    
    // Initialize visibility based on initial proof type
    if (this.hasProofTypeTarget) {
      this._updateReasonGroupsVisibility(this.proofTypeTarget.value)
    }
  }

  // Stimulus action for handling proof type selection
  // HTML: data-action="click->rejection-form#handleProofTypeClick"
  handleProofTypeClick(event) {
    const proofType = event.currentTarget.dataset.proofType
    if (proofType && this.hasProofTypeTarget) {
      this.proofTypeTarget.value = proofType
      this._updateReasonGroupsVisibility(proofType)
    }
  }
  
  // Private method for managing reason group visibility
  _updateReasonGroupsVisibility(proofType) {
    // Early exit if no reason group targets exist
    if (!this.hasIncomeOnlyReasonsTarget && !this.hasMedicalOnlyReasonsTarget && !this.hasGeneralReasonsTarget) {
      return
    }

    // Handle empty or unknown proof types gracefully - reset all groups to hidden
    if (!proofType) {
      if (this.hasIncomeOnlyReasonsTarget) setVisible(this.incomeOnlyReasonsTarget, false, { ariaHidden: true })
      if (this.hasMedicalOnlyReasonsTarget) setVisible(this.medicalOnlyReasonsTarget, false, { ariaHidden: true })
      if (this.hasGeneralReasonsTarget) setVisible(this.generalReasonsTarget, false, { ariaHidden: true })
      return
    }
    
    // Use symmetric logic for all reason groups
    const isIncome = proofType === 'income'
    const isMedical = proofType === 'medical'
    
    const groups = [
      { target: this.hasIncomeOnlyReasonsTarget ? this.incomeOnlyReasonsTarget : null, show: isIncome },
      { target: this.hasMedicalOnlyReasonsTarget ? this.medicalOnlyReasonsTarget : null, show: isMedical },
      { target: this.hasGeneralReasonsTarget ? this.generalReasonsTarget : null, show: !isMedical }
    ]
    
    // Apply visibility with ARIA support
    groups.forEach(({ target, show }) => {
      if (target) setVisible(target, show, { ariaHidden: !show })
    })
  }

  // Handle predefined reason selection
  selectPredefinedReason(event) {
    if (!this.hasReasonFieldTarget) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing reason field target for predefined reason selection')
      }
      return
    }

    const reasonType = event.currentTarget.dataset.reasonType
    if (!reasonType) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing reason type in button data attribute')
      }
      return
    }

    // Get the proof type from the hidden field, defaulting to a sensible value if missing
    // Note: 'general' serves as fallback for both income and residency proof types
    let proofType = 'general'
    if (this.hasProofTypeTarget && this.proofTypeTarget.value) {
      proofType = this.proofTypeTarget.value
      if (process.env.NODE_ENV !== 'production') {
        console.log(`Using proof type from field: ${proofType}`)
      }
    } else {
      // Try to infer from context - check if this is inside the medical certification modal
      const isMedicalModal = event.currentTarget.closest('#medicalCertificationRejectionModal')
      if (isMedicalModal) {
        proofType = 'medical'
        if (process.env.NODE_ENV !== 'production') {
          console.log('Inferred medical proof type from modal context')
        }
      }
    }

    const reasonText = this._lookupReason(reasonType, proofType)
    
    if (reasonText) {
      this.reasonFieldTarget.value = reasonText
      this.reasonFieldTarget.classList.remove('border-red-500')
    } else {
      if (process.env.NODE_ENV !== 'production') {
        console.warn(`No predefined reason found for type: ${reasonType}, proof type: ${proofType}`)
      }
    }
  }

  // Private helper for DRY reason lookup with early returns
  _lookupReason(reasonType, proofType) {
    let reasonText = null

    // For medical certification reasons
    if (proofType === 'medical') {
      reasonText = this[`${reasonType}Value`]
      if (process.env.NODE_ENV !== 'production') {
        console.log(`Looking for medical reason: ${reasonType}Value = ${reasonText ? 'Found' : 'Not found'}`)
      }
      if (reasonText) return reasonText
    } else {
      // For income/residency, use the composite key approach
      const key = `${reasonType}${proofType.charAt(0).toUpperCase() + proofType.slice(1)}`
      reasonText = this[`${key}Value`]
      if (process.env.NODE_ENV !== 'production') {
        console.log(`Looking for ${proofType} reason: ${key}Value = ${reasonText ? 'Found' : 'Not found'}`)
      }
      if (reasonText) return reasonText
    }
    
    // No fallback needed - Stimulus values should handle all cases
    return null
  }

  // Handle form validation
  validateForm(event) {
    if (!this.hasReasonFieldTarget) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing reason field target')
      }
      return
    }

    if (!this.hasProofTypeTarget || !this.proofTypeTarget.value) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing proof type')
      }
      event.preventDefault()
      return
    }

    const reasonField = this.reasonFieldTarget
    const reasonText = reasonField.value.trim()

    if (!reasonText) {
      event.preventDefault()
      reasonField.classList.add('border-red-500')
      reasonField.focus()
      return
    }

    reasonField.classList.remove('border-red-500')
    
    // Notify any parent modal controllers that a form is being submitted
    // This helps ensure proper scroll restoration after the form submission
    document.dispatchEvent(new CustomEvent('turbo-form-submit', {
      detail: { 
        element: event.target,
        controller: this
      }
    }));
    
    if (process.env.NODE_ENV !== 'production') {
      console.log("Form submission validated, proceeding with submit");
    }
  }
}
