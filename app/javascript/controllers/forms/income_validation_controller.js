import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"
import { calculateThreshold as calculateThresholdUtil } from "../../services/income_threshold"

/**
 * Compares annual income with FPL (Federal Poverty Level) thresholds for the household size.
 * Shows warnings and dispatches validation state. The form controllers own final submit readiness.
 */
class IncomeValidationController extends Controller {
  static targets = [
    "householdSize", "annualIncome", "warningContainer", "incomeFieldsContainer", "noIncomeProvided"
  ]

  static outlets = ["flash"]
  static values = {
    fplThresholds: String,  // Server-rendered JSON of base FPL amounts.
    modifier: Number // Policy percentage of base FPL.
  }

  connect() {
    try {
      this.fplThresholds = JSON.parse(this.fplThresholdsValue)
    } catch (error) {
      console.error("Failed to parse FPL thresholds:", error)
      this.fplThresholds = {}
    }
    
    // Reuse this bound listener during disconnect.
    this._validate = this.validateIncomeThreshold.bind(this)

    this.setupEventListeners()

    // Currency formatting can change the raw value after the input event.
    this._onCurrencyRawUpdate = () => this.validateIncomeThreshold()
    this._onCurrencyFormatted = () => this.validateIncomeThreshold()
    try {
      this.element.addEventListener('currency-formatter:rawValueUpdated', this._onCurrencyRawUpdate)
      this.element.addEventListener('currency-formatter:formatted', this._onCurrencyFormatted)
    } catch (_) {
      // Listener setup failure does not prevent controller initialization.
    }

    this.element.dataset.fplLoaded = "true"
    this.element.classList.add("fpl-data-loaded")
    this.dispatch("fpl-data-loaded")
    this.toggleIncomeRequirement()
  }

  disconnect() {
    this.teardownEventListeners()
    try {
      if (this._onCurrencyRawUpdate) this.element.removeEventListener('currency-formatter:rawValueUpdated', this._onCurrencyRawUpdate)
      if (this._onCurrencyFormatted) this.element.removeEventListener('currency-formatter:formatted', this._onCurrencyFormatted)
    } catch (_) {
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
    if (this.incomeActionDefersReview()) {
      this.clearValidationState()
      return
    }

    const size = this.getHouseholdSize()
    const income = this.getAnnualIncome()

    if (size < 1 || income < 1) {
      this.clearValidationState()
      return
    }

    const threshold = this.calculateThresholdForSize(size)
    const exceedsThreshold = (income - threshold) > 0.0001


    this.updateValidationUI(exceedsThreshold, threshold)

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
      const value = target.value
      const rawValue = target.dataset.rawValue
      const inputType = (target.getAttribute('type') || '').toLowerCase()
      const hasNonNumericChars = /[^0-9.\-]/.test(value)

      // Text inputs can contain currency formatting, so prefer their raw value.
      if (rawValue && (inputType === 'text' || hasNonNumericChars)) {
        return parseFloat(rawValue) || 0
      }

      // A number input can change before its cached raw value updates.
      const parsed = parseFloat(value)
      if (!Number.isNaN(parsed)) return parsed
      return parseFloat((value || '').replace(/[^\d.-]/g, '')) || 0
    }
    return 0
  }

  calculateThresholdForSize(householdSize) {
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
    // The hidden attribute controls visibility without CSS.
    try { target.removeAttribute('hidden') } catch (_) {}
    target.setAttribute("role", "alert")
  }

  hideWarning(target) {
    setVisible(target, false)
    // The hidden attribute controls visibility without CSS.
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

  clearValidationState() {
    if (this.hasWarningContainerTarget) {
      this.hideWarning(this.warningContainerTarget)
    }
    this.resetIncomeFieldsContainerStyle()
    // Form controllers must recompute submit readiness when the income block clears.
    this.dispatch("validated", {
      detail: {
        exceedsThreshold: false,
        income: 0,
        threshold: 0,
        householdSize: 0
      }
    })
  }

  updateIncomeFieldsContainerStyle(exceedsThreshold) {
    if (!this.hasIncomeFieldsContainerTarget) return

    const container = this.incomeFieldsContainerTarget
    container.classList.remove(
      'bg-gray-50', 'border-gray-200',
      'bg-green-50', 'border-green-300',
      'bg-red-50', 'border-red-300'
    )

    if (exceedsThreshold) {
      container.classList.add('bg-red-50', 'border-red-300')
    } else {
      container.classList.add('bg-green-50', 'border-green-300')
    }
  }

  resetIncomeFieldsContainerStyle() {
    if (!this.hasIncomeFieldsContainerTarget) return

    const container = this.incomeFieldsContainerTarget
    container.classList.remove(
      'bg-green-50', 'border-green-300',
      'bg-red-50', 'border-red-300'
    )
    container.classList.add('bg-gray-50', 'border-gray-200')
  }


  validateAction() {
    this.validateIncomeThreshold()
  }

  toggleIncome() {
    this.toggleIncomeRequirement()
  }

  toggleIncomeRequirement() {
    if (!this.hasNoIncomeProvidedTarget || !this.hasIncomeFieldsContainerTarget) return

    const incomeMissing = this.noIncomeProvidedTarget.checked
    const detailsRequired = this.incomeActionRequiresDetails() && !incomeMissing

    setVisible(this.incomeFieldsContainerTarget, !incomeMissing)
    this.setIncomeFieldsRequired(detailsRequired)

    if (detailsRequired) {
      this.validateIncomeThreshold()
    } else {
      this.clearValidationState()
    }
  }

  incomeActionRequiresDetails() {
    const selectedAction = this.element.querySelector('input[name="income_proof_action"]:checked')
    return selectedAction?.value === 'accept'
  }

  incomeActionDefersReview() {
    const selectedAction = this.element.querySelector('input[name="income_proof_action"]:checked')
    return selectedAction?.value === 'upload_only'
  }

  setIncomeFieldsRequired(required) {
    [
      this.hasHouseholdSizeTarget ? this.householdSizeTarget : null,
      this.hasAnnualIncomeTarget ? this.annualIncomeTarget : null
    ].filter(Boolean).forEach((target) => {
      if (required) {
        target.setAttribute('required', 'required')
        target.setAttribute('aria-required', 'true')
      } else {
        target.removeAttribute('required')
        target.removeAttribute('aria-required')
      }
    })
  }

}


export default IncomeValidationController
