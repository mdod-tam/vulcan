import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = [
    "proofType",         // Hidden input for proof type
    "reasonCode",        // Hidden input for rejection_reason_code (snake_case DB key)
    "reasonButton",      // Predefined rejection reason buttons
    "reasonField",       // Text area for rejection reason
    "languageNotice",    // Reminder shown only for custom "Other" reasons
    "codeStatus",        // Visible status text for code linkage
    "liveRegion",        // aria-live region for announcing reason selection
    "medicalOnlyReasons", // Medical-specific rejection reasons container
    "generalReasons"     // General rejection reasons container (income/residency/id)
  ]

  static values = {}

  connect() {
    this._boundProofTypeChanged = this._handleProofTypeChanged.bind(this)

    if (this.hasReasonFieldTarget) {
      this.reasonFieldTarget.value = ""
      this.reasonFieldTarget.classList.remove('border-red-500')
      this._lockReasonField()
    }
    this._hideLanguageNotice()
    this._resetReasonCodeState()

    this._initializeReasonButtons()
    this._syncGroupInteractivity()
    
    if (this.hasProofTypeTarget && this.proofTypeTarget.value) {
      this._updateReasonGroupsVisibility(this.proofTypeTarget.value)
    }
    
    this.element.addEventListener('proof-type-changed', this._boundProofTypeChanged)
  }
  
  disconnect() {
    this.element.removeEventListener('proof-type-changed', this._boundProofTypeChanged)
  }
  
  _handleProofTypeChanged(event) {
    const proofType = event.detail.proofType
    if (process.env.NODE_ENV !== 'production') {
      console.log('RejectionForm: Received proof type changed event:', proofType)
    }
    if (this.hasProofTypeTarget) {
      this.proofTypeTarget.value = proofType
      this._resetReasonCodeState()
      if (this.hasReasonFieldTarget) {
        this.reasonFieldTarget.value = ""
        this._lockReasonField()
      }
      this._setSelectedReasonButton(event.currentTarget)
      this._hideLanguageNotice()
      this._updateReasonGroupsVisibility(proofType)
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
    if (!this.hasMedicalOnlyReasonsTarget && !this.hasGeneralReasonsTarget) {
      if (process.env.NODE_ENV !== 'production') {
        console.log('RejectionForm: No reason group targets found')
      }
      return
    }

    // Handle empty or unknown proof types gracefully - reset all groups to hidden
    if (!proofType) {
      if (this.hasMedicalOnlyReasonsTarget) setVisible(this.medicalOnlyReasonsTarget, false, { ariaHidden: true, inlineStyleFallback: false })
      if (this.hasGeneralReasonsTarget) setVisible(this.generalReasonsTarget, false, { ariaHidden: true, inlineStyleFallback: false })
      return
    }

    // Use symmetric logic for all reason groups
    const isMedical = proofType === 'medical'

    if (process.env.NODE_ENV !== 'production') {
      console.log('RejectionForm: isMedical:', isMedical)
    }

    const groups = [
      { target: this.hasMedicalOnlyReasonsTarget ? this.medicalOnlyReasonsTarget : null, show: isMedical, name: 'medical' },
      { target: this.hasGeneralReasonsTarget ? this.generalReasonsTarget : null, show: !isMedical, name: 'general' }
    ]

    // Apply visibility to groups
    groups.forEach(({ target, show, name }) => {
      if (target) {
        if (process.env.NODE_ENV !== 'production') {
          console.log(`RejectionForm: Setting ${name} group visibility to ${show}`)
        }
        setVisible(target, show, { ariaHidden: !show, inlineStyleFallback: false })
      }
    })

    // Filter individual reason buttons based on proof-type attribute
    if (this.hasReasonButtonTarget) {
      this.reasonButtonTargets.forEach(button => {
        const proofTypes = button.dataset.proofTypes
        if (proofTypes) {
          const allowedTypes = proofTypes.split(',')
          const shouldShow = allowedTypes.includes(proofType)
          setVisible(button, shouldShow, { ariaHidden: !shouldShow, inlineStyleFallback: false })
        }
      })
    }
  }

  // Handle predefined reason selection
  selectPredefinedReason(event) {
    if (!this.hasReasonFieldTarget) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing reason field target for predefined reason selection')
      }
      return
    }

    const reasonText = event.currentTarget.dataset.reasonText
    const reasonCode = event.currentTarget.dataset.reasonCode || null

    if (!reasonText) {
      if (process.env.NODE_ENV !== 'production') {
        console.warn('Missing reason text in button data attribute')
      }
      return
    }

    if (process.env.NODE_ENV !== 'production') {
      console.log(`RejectionForm: selectPredefinedReason called with reasonCode: ${reasonCode}`)
    }

    this.reasonFieldTarget.value = reasonText
    this.reasonFieldTarget.classList.remove('border-red-500')
    this._lockReasonField()
    this._hideLanguageNotice()
    if (this.hasReasonCodeTarget) {
      this.reasonCodeTarget.value = reasonCode || ""
    }
    this._setSelectedReasonButton(event.currentTarget)
    this._setCodeStatus(`Using predefined reason: ${reasonCode || 'none'}.`, 'linked')
  }

  selectOther(event) {
    if (!this.hasReasonFieldTarget) return

    this.reasonFieldTarget.value = ""
    this._unlockReasonField()
    this._resetReasonSelection()
    this._showLanguageNotice()
    this._setSelectedReasonButton(event.currentTarget)
    if (this.hasReasonCodeTarget) {
      this.reasonCodeTarget.value = "other"
    }
    this._setCodeStatus('Custom reason — type your rejection reason below.', 'unlinked')
    this._announceReasonSelection('Other (custom reason)')
    this.reasonFieldTarget.focus()
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

  _lockReasonField() {
    if (!this.hasReasonFieldTarget) return
    this.reasonFieldTarget.readOnly = true
    this.reasonFieldTarget.classList.add('bg-gray-100', 'text-gray-600')
  }

  _unlockReasonField() {
    if (!this.hasReasonFieldTarget) return
    this.reasonFieldTarget.readOnly = false
    this.reasonFieldTarget.classList.remove('bg-gray-100', 'text-gray-600')
  }

  _showLanguageNotice() {
    if (!this.hasLanguageNoticeTarget) return
    this.languageNoticeTarget.classList.remove('hidden')
  }

  _hideLanguageNotice() {
    if (!this.hasLanguageNoticeTarget) return
    this.languageNoticeTarget.classList.add('hidden')
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
