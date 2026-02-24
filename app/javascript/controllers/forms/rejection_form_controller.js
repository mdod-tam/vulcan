import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = [
    "proofType",         // Hidden input for proof type
    "reasonCode",        // Hidden input for rejection_reason_code (snake_case DB key)
    "reasonButton",      // Predefined rejection reason buttons
    "reasonField",       // Text area for rejection reason
    "codeStatus",        // Visible status text for code linkage
    "liveRegion",        // aria-live region for announcing reason selection
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
    this._boundProofTypeChanged = this._handleProofTypeChanged.bind(this)
    this._boundReasonFieldInput = () => {
      this._clearReasonCode()
      this._resetReasonSelection()
    }

    // Clear form on connect and reset any error styling
    if (this.hasReasonFieldTarget) {
      this.reasonFieldTarget.value = ""
      this.reasonFieldTarget.classList.remove('border-red-500')
      // Clear the code whenever the admin manually edits the textarea (free text = no code)
      this.reasonFieldTarget.addEventListener('input', this._boundReasonFieldInput)
    }
    this._resetReasonCodeState()

    this._initializeReasonButtons()
    this._syncGroupInteractivity()
    
    // Initialize visibility based on initial proof type only if it has a value
    if (this.hasProofTypeTarget && this.proofTypeTarget.value) {
      this._updateReasonGroupsVisibility(this.proofTypeTarget.value)
    }
    
    // Listen for proof type changes from modal controller
    this.element.addEventListener('proof-type-changed', this._boundProofTypeChanged)
  }
  
  disconnect() {
    this.element.removeEventListener('proof-type-changed', this._boundProofTypeChanged)
    if (this.hasReasonFieldTarget) {
      this.reasonFieldTarget.removeEventListener('input', this._boundReasonFieldInput)
    }
  }
  
  _handleProofTypeChanged(event) {
    const proofType = event.detail.proofType
    if (process.env.NODE_ENV !== 'production') {
      console.log('RejectionForm: Received proof type changed event:', proofType)
    }
    if (this.hasProofTypeTarget) {
      this.proofTypeTarget.value = proofType
      this._resetReasonCodeState()
      this._updateReasonGroupsVisibility(proofType)
      if (process.env.NODE_ENV !== 'production') {
        console.log('RejectionForm: Updated visibility for proof type:', proofType)
      }
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
    if (process.env.NODE_ENV !== 'production') {
      console.log('RejectionForm: _updateReasonGroupsVisibility called with proof type:', proofType)
    }
    
    // Early exit if no reason group targets exist
    if (!this.hasIncomeOnlyReasonsTarget && !this.hasMedicalOnlyReasonsTarget && !this.hasGeneralReasonsTarget) {
      if (process.env.NODE_ENV !== 'production') {
        console.log('RejectionForm: No reason group targets found')
      }
      return
    }

    // Handle empty or unknown proof types gracefully - reset all groups to hidden
    if (!proofType) {
      if (this.hasIncomeOnlyReasonsTarget) setVisible(this.incomeOnlyReasonsTarget, false, { ariaHidden: true, inlineStyleFallback: false })
      if (this.hasMedicalOnlyReasonsTarget) setVisible(this.medicalOnlyReasonsTarget, false, { ariaHidden: true, inlineStyleFallback: false })
      if (this.hasGeneralReasonsTarget) setVisible(this.generalReasonsTarget, false, { ariaHidden: true, inlineStyleFallback: false })
      return
    }
    
    // Use symmetric logic for all reason groups
    const isIncome = proofType === 'income'
    const isMedical = proofType === 'medical'
    
    if (process.env.NODE_ENV !== 'production') {
      console.log('RejectionForm: isIncome:', isIncome, 'isMedical:', isMedical)
    }
    
    const groups = [
      { target: this.hasIncomeOnlyReasonsTarget ? this.incomeOnlyReasonsTarget : null, show: isIncome, name: 'income' },
      { target: this.hasMedicalOnlyReasonsTarget ? this.medicalOnlyReasonsTarget : null, show: isMedical, name: 'medical' },
      { target: this.hasGeneralReasonsTarget ? this.generalReasonsTarget : null, show: !isMedical, name: 'general' }
    ]
    
    // Apply visibility with ARIA support
    groups.forEach(({ target, show, name }) => {
      if (target) {
        if (process.env.NODE_ENV !== 'production') {
          console.log(`RejectionForm: Setting ${name} group visibility to ${show}`)
        }
        setVisible(target, show, { ariaHidden: !show, inlineStyleFallback: false })
      }
    })

    this._resetReasonSelection()
    this._syncGroupInteractivity()
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
    const reasonCode = event.currentTarget.dataset.reasonCode || null

    if (reasonText) {
      this.reasonFieldTarget.value = reasonText
      this.reasonFieldTarget.classList.remove('border-red-500')
      if (this.hasReasonCodeTarget) {
        this.reasonCodeTarget.value = reasonCode || ""
      }
      this._setSelectedReasonButton(event.currentTarget)
      this._setCodeStatus(`Linked to predefined reason code: ${reasonCode || 'none'}.`, 'linked')
      this._announceReasonSelection(event.currentTarget.textContent.trim())
      this.reasonFieldTarget.focus()
      const textLength = this.reasonFieldTarget.value.length
      this.reasonFieldTarget.setSelectionRange(textLength, textLength)
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

  // Clears the reason code when the admin edits the textarea directly.
  // A manual edit means the text is no longer tied to a predefined code.
  _clearReasonCode() {
    if (this.hasReasonCodeTarget && this.reasonCodeTarget.value) {
      this.reasonCodeTarget.value = ""
      this._setCodeStatus('Custom edits detected. Predefined reason link removed.', 'unlinked')
      this._announceCustomEditUnlinked()
    }
  }

  _initializeReasonButtons() {
    if (!this.hasReasonButtonTarget) return

    this.reasonButtonTargets.forEach((button) => {
      button.setAttribute('aria-pressed', 'false')
      this._applyReasonButtonState(button, false)
    })
  }

  _resetReasonSelection() {
    if (!this.hasReasonButtonTarget) return

    this.reasonButtonTargets.forEach((button) => {
      button.setAttribute('aria-pressed', 'false')
      this._applyReasonButtonState(button, false)
    })
  }

  _setSelectedReasonButton(selectedButton) {
    this._resetReasonSelection()
    selectedButton.setAttribute('aria-pressed', 'true')
    this._applyReasonButtonState(selectedButton, true)
  }

  _applyReasonButtonState(button, selected) {
    const selectedClasses = ['bg-indigo-600', 'text-white', 'border-indigo-700']
    const unselectedClasses = ['bg-gray-100', 'text-gray-800', 'border-gray-300']

    if (selected) {
      button.classList.remove(...unselectedClasses)
      button.classList.add(...selectedClasses)
    } else {
      button.classList.remove(...selectedClasses)
      button.classList.add(...unselectedClasses)
    }
  }

  _announceReasonSelection(reasonLabel) {
    if (!this.hasLiveRegionTarget) return

    this.liveRegionTarget.textContent = ''
    requestAnimationFrame(() => {
      this.liveRegionTarget.textContent = `Selected rejection reason: ${reasonLabel}. Reason text inserted in the reason field.`
    })
  }

  _announceCustomEditUnlinked() {
    if (!this.hasLiveRegionTarget) return

    this.liveRegionTarget.textContent = ''
    requestAnimationFrame(() => {
      this.liveRegionTarget.textContent = 'Custom edits detected. Predefined reason code link removed.'
    })
  }

  _setCodeStatus(message, state = 'neutral') {
    if (!this.hasCodeStatusTarget) return

    const status = this.codeStatusTarget
    status.textContent = message
    status.classList.remove('text-gray-500', 'text-emerald-700', 'text-amber-700')

    if (state === 'linked') {
      status.classList.add('text-emerald-700')
    } else if (state === 'unlinked') {
      status.classList.add('text-amber-700')
    } else {
      status.classList.add('text-gray-500')
    }
  }

  _resetReasonCodeState() {
    if (this.hasReasonCodeTarget) {
      this.reasonCodeTarget.value = ""
    }
    this._setCodeStatus('No predefined rejection reason selected.', 'neutral')
  }

  _syncGroupInteractivity() {
    const groups = [
      this.hasIncomeOnlyReasonsTarget ? this.incomeOnlyReasonsTarget : null,
      this.hasMedicalOnlyReasonsTarget ? this.medicalOnlyReasonsTarget : null,
      this.hasGeneralReasonsTarget ? this.generalReasonsTarget : null
    ].filter(Boolean)

    groups.forEach((group) => this._setGroupButtonInteractivity(group, this._isGroupVisible(group)))
  }

  _isGroupVisible(group) {
    return !group.classList.contains('hidden') &&
      group.getAttribute('aria-hidden') !== 'true' &&
      group.style.display !== 'none'
  }

  _setGroupButtonInteractivity(group, enabled) {
    const buttons = group.querySelectorAll("button[data-rejection-form-target='reasonButton']")
    buttons.forEach((button) => {
      button.disabled = !enabled
      if (enabled) {
        button.removeAttribute('tabindex')
      } else {
        button.setAttribute('tabindex', '-1')
      }
    })
  }
}
