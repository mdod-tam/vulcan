import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"
import { calculateThreshold as calculateThresholdUtil } from "../../services/income_threshold"

/**
 * Income Validation Controller
 * 
 * Validates that annual income is within FPL (Federal Poverty Level) thresholds
 * for the given household size. Shows warnings and disables submission if income
 * exceeds the threshold.
 */
class IncomeValidationController extends Controller {
  static targets = [
    "householdSize", "annualIncome", "warningContainer", "submitButton", "incomeFieldsContainer", "noIncomeProvided"
  ]

  static outlets = ["flash"] // Declare flash outlet
  static values = {
    fplThresholds: String,  // JSON string of FPL thresholds
    modifier: Number // FPL modifier percentage from policy
  }

  connect() {
    // Parse FPL thresholds from server-rendered data
    try {
      this.fplThresholds = JSON.parse(this.fplThresholdsValue)
    } catch (error) {
      console.error("Failed to parse FPL thresholds:", error)
      this.fplThresholds = {}
    }
    
    // Bind method for event listener cleanup
    this._validate = this.validateIncomeThreshold.bind(this)

    this.setupEventListeners()

    // Listen for currency formatter updates to re-validate immediately after formatting/blur
    this._onCurrencyRawUpdate = () => this.validateIncomeThreshold()
    this._onCurrencyFormatted = () => this.validateIncomeThreshold()
    try {
      this.element.addEventListener('currency-formatter:rawValueUpdated', this._onCurrencyRawUpdate)
      this.element.addEventListener('currency-formatter:formatted', this._onCurrencyFormatted)
    } catch (_) {
      // no-op: event wiring is best-effort
    }

    // Mark as loaded and validate initial state
    this.element.dataset.fplLoaded = "true"
    this.element.classList.add("fpl-data-loaded")
    this.dispatch("fpl-data-loaded")
    this.validateIncomeThreshold()
  }

  disconnect() {
    this.teardownEventListeners()
    try {
      if (this._onCurrencyRawUpdate) this.element.removeEventListener('currency-formatter:rawValueUpdated', this._onCurrencyRawUpdate)
      if (this._onCurrencyFormatted) this.element.removeEventListener('currency-formatter:formatted', this._onCurrencyFormatted)
    } catch (_) {
      // no-op
    }
  }

  setupEventListeners() {
    if (this.hasHouseholdSizeTarget) {
      const target = this.householdSizeTarget
      target.addEventListener("input", this._validate)
      target.addEventListener("change", this._validate)
      target.addEventListener("blur", this._validate, true)
    }

    if (this.hasAnnualIncomeTarget) {
      const target = this.annualIncomeTarget
      target.addEventListener("input", this._validate)
      target.addEventListener("change", this._validate)
      target.addEventListener("blur", this._validate, true)
    }
  }

  teardownEventListeners() {
    if (this.hasHouseholdSizeTarget) {
      const target = this.householdSizeTarget
      target.removeEventListener("input", this._validate)
      target.removeEventListener("change", this._validate)
      target.removeEventListener("blur", this._validate, true)
    }

    if (this.hasAnnualIncomeTarget) {
      const target = this.annualIncomeTarget
      target.removeEventListener("input", this._validate)
      target.removeEventListener("change", this._validate)
      target.removeEventListener("blur", this._validate, true)
    }
  }


  validateIncomeThreshold() {
    const size = this.getHouseholdSize()
    const income = this.getAnnualIncome()

    // Skip validation if inputs are invalid
    if (size < 1 || income < 1) {
      this.clearValidationState()
      return
    }

    const threshold = this.calculateThresholdForSize(size)
    const exceedsThreshold = (income - threshold) > 0.0001


    this.updateValidationUI(exceedsThreshold, threshold)

    // Dispatch custom event for other controllers to listen to
    this.dispatch("validated", {
      detail: {
        exceedsThreshold,
        income,
        threshold,
        householdSize: size
      }
    })
  }

  getHouseholdSize() {
    if (this.hasHouseholdSizeTarget) {
      const target = this.householdSizeTarget
      return parseInt(target.value, 10) || 0
    }
    return 0
  }

  getAnnualIncome() {
    if (this.hasAnnualIncomeTarget) {
      const target = this.annualIncomeTarget
      // Handle both formatted and raw input values
      const value = target.value
      const rawValue = target.dataset.rawValue
      const inputType = (target.getAttribute('type') || '').toLowerCase()
      const hasNonNumericChars = /[^0-9.\-]/.test(value)

      // Prefer rawValue only for text inputs or when formatted characters are present
      if (rawValue && (inputType === 'text' || hasNonNumericChars)) {
        return parseFloat(rawValue) || 0
      }

      // For number inputs or plain numeric values, trust the visible value
      const parsed = parseFloat(value)
      if (!Number.isNaN(parsed)) return parsed
      return parseFloat((value || '').replace(/[^\d.-]/g, '')) || 0
    }
    return 0
  }

  calculateThresholdForSize(householdSize) {
    // Use server-rendered data with fallback to prevent failures
    const fallbackFpl = {
      1: 15650, 2: 21150, 3: 26650, 4: 32150,
      5: 37650, 6: 43150, 7: 48650, 8: 54150
    }

    const baseFplBySize = (this.fplThresholds && typeof this.fplThresholds === 'object' && Object.keys(this.fplThresholds).length > 0)
      ? this.fplThresholds
      : fallbackFpl

    const modifierPercent = (typeof this.modifierValue === 'number' && !Number.isNaN(this.modifierValue))
      ? this.modifierValue
      : 400

    return calculateThresholdUtil({ baseFplBySize, modifierPercent, householdSize })
  }

  updateValidationUI(exceedsThreshold, threshold) {
    this.updateWarningDisplay(exceedsThreshold, threshold)
    this.updateSubmitButton(exceedsThreshold)
    this.updateIncomeFieldsContainerStyle(exceedsThreshold)
  }

  updateWarningDisplay(exceedsThreshold, threshold) {
    if (this.hasWarningContainerTarget) {
      const target = this.warningContainerTarget
      if (exceedsThreshold) {
        this.showWarning(target, threshold)
      } else {
        this.hideWarning(target)
      }
    }
  }

  showWarning(target, threshold) {
    target.innerHTML = this.buildWarningHTML(threshold)
    setVisible(target, true)
    // Ensure HTML hidden attribute is removed in environments without CSS
    try { target.removeAttribute('hidden') } catch (_) {}
    target.setAttribute("role", "alert")
  }

  hideWarning(target) {
    setVisible(target, false)
    // Ensure HTML hidden attribute is set in environments without CSS
    try { if (!target.hasAttribute('hidden')) target.setAttribute('hidden', '') } catch (_) {}
    target.removeAttribute("role")
  }

  buildWarningHTML(threshold) {
    const formattedThreshold = threshold.toLocaleString('en-US', {
      style: 'currency',
      currency: 'USD',
      minimumFractionDigits: 2,
      maximumFractionDigits: 2
    })

    return `
      <div class="bg-red-600 border-2 border-red-700 text-white font-bold p-4 rounded-md">
        <h3 class="font-bold text-lg">Income Exceeds Threshold</h3>
        <p>Your annual income exceeds the maximum threshold of ${formattedThreshold} for your household size.</p>
        <p>Applications with income above the threshold are not eligible for this program.</p>
      </div>
    `
  }

  updateSubmitButton(exceedsThreshold) {
    if (this.hasSubmitButtonTarget) {
      const target = this.submitButtonTarget
      const prev = target.disabled
      if (prev === exceedsThreshold) return
      target.disabled = exceedsThreshold

      if (exceedsThreshold) {
        target.classList.add("opacity-50", "cursor-not-allowed")
        target.setAttribute("disabled", "disabled")
      } else {
        target.classList.remove("opacity-50", "cursor-not-allowed")
        target.removeAttribute("disabled")
      }
    }
  }

  clearValidationState() {
    if (this.hasWarningContainerTarget) {
      this.hideWarning(this.warningContainerTarget)
    }
    this.updateSubmitButton(false)
    this.resetIncomeFieldsContainerStyle()
  }

  /**
   * Updates the income fields container background to provide visual feedback
   * Green = income within threshold, Red = income exceeds threshold
   */
  updateIncomeFieldsContainerStyle(exceedsThreshold) {
    if (!this.hasIncomeFieldsContainerTarget) return

    const container = this.incomeFieldsContainerTarget
    // Remove all validation-related classes first
    container.classList.remove(
      'bg-gray-50', 'border-gray-200',
      'bg-green-50', 'border-green-300',
      'bg-red-50', 'border-red-300'
    )

    if (exceedsThreshold) {
      // Red background for exceeds threshold
      container.classList.add('bg-red-50', 'border-red-300')
    } else {
      // Green background for within threshold
      container.classList.add('bg-green-50', 'border-green-300')
    }
  }

  /**
   * Resets the income fields container to neutral state (gray)
   */
  resetIncomeFieldsContainerStyle() {
    if (!this.hasIncomeFieldsContainerTarget) return

    const container = this.incomeFieldsContainerTarget
    container.classList.remove(
      'bg-green-50', 'border-green-300',
      'bg-red-50', 'border-red-300'
    )
    container.classList.add('bg-gray-50', 'border-gray-200')
  }


  // Action methods for manual triggering
  validateAction() {
    this.validateIncomeThreshold()
  }

  toggleIncome() {
    const incomeMissing = this.noIncomeProvidedTarget.checked
    setVisible(this.incomeFieldsContainerTarget, !incomeMissing)
    if (incomeMissing) {
      this.householdSizeTarget.removeAttribute('required')
      this.annualIncomeTarget.removeAttribute('required')
    } else {
      this.householdSizeTarget.setAttribute('required', 'required')
      this.annualIncomeTarget.setAttribute('required', 'required')
    }
  }

}

// Apply target safety mixin

export default IncomeValidationController
