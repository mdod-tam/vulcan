import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";

export default class extends Controller {
  static targets = [
    "submitButton",
    "rejectionButton",
    // Hidden field targets in the rejection modal
    "rejectionFirstName",
    "rejectionLastName",
    "rejectionEmail",
    "rejectionPhone",
    "rejectionHouseholdSize",
    "rejectionAnnualIncome"
  ];

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("PaperApplicationController connected");
    }

    // Listen for income validation events from income_validation_controller
    this._boundHandleIncomeValidation = this.handleIncomeValidation.bind(this);
    this.element.addEventListener('income-validation:validated', this._boundHandleIncomeValidation);
  }

  disconnect() {
    // Clean up event listeners
    if (this._boundHandleIncomeValidation) {
      this.element.removeEventListener('income-validation:validated', this._boundHandleIncomeValidation);
    }
  }

  /**
   * Handle income validation results from income_validation_controller
   * @param {CustomEvent} event The validation event with details about threshold status
   */
  handleIncomeValidation(event) {
    const { exceedsThreshold } = event.detail;
    this.updateSubmissionUI(exceedsThreshold);
  }

  /**
   * Update submission UI based on income threshold validation
   * @param {boolean} exceedsThreshold Whether income exceeds threshold
   */
  updateSubmissionUI(exceedsThreshold) {
    if (this.hasSubmitButtonTarget) {
      // Setting the property AND the attribute for the selector to match
      this.submitButtonTarget.disabled = exceedsThreshold;

      // This is critical: For the CSS selector input[type=submit][disabled] to match,
      // we need to set the HTML attribute, not just the JS property
      if (exceedsThreshold) {
        this.submitButtonTarget.setAttribute('disabled', 'disabled');
      } else {
        this.submitButtonTarget.removeAttribute('disabled');
      }
    }

    if (this.hasRejectionButtonTarget) {
      setVisible(this.rejectionButtonTarget, exceedsThreshold);
    } else if (exceedsThreshold) {
      console.warn("Missing rejectionButton target - check HTML structure");
    }
  }

  /**
   * Temporary method to prevent errors - this functionality should be handled by income-validation controller
   * TODO: Replace with proper income-validation controller setup
   */
  validateIncomeThreshold() {
    if (process.env.NODE_ENV !== 'production') {
      console.warn('validateIncomeThreshold called on paper-application controller - this should be handled by income-validation controller');
    }
    // For now, prevent the error - the income validation should be handled elsewhere
  }

  /**
   * Open the rejection modal and populate hidden fields with data from the main form.
   * Uses native <dialog> showModal() API for proper accessibility.
   */
  openRejectionModal() {
    const dialog = document.getElementById('rejection-modal');
    if (!dialog) {
      console.error('Rejection modal not found');
      return;
    }

    // Populate hidden fields from main form values
    this._populateRejectionModalFields();

    // Open the dialog using native API
    if (dialog.tagName === 'DIALOG') {
      dialog.showModal();
    } else {
      console.warn('rejection-modal is not a <dialog> element');
      setVisible(dialog, true);
    }
  }

  /**
   * Populate the rejection modal hidden fields with values from the main form
   * @private
   */
  _populateRejectionModalFields() {
    // Get values from main form fields
    const firstName = this.element.querySelector('[name="constituent[first_name]"]')?.value ||
                      this.element.querySelector('[name="guardian_attributes[first_name]"]')?.value || '';
    const lastName = this.element.querySelector('[name="constituent[last_name]"]')?.value ||
                     this.element.querySelector('[name="guardian_attributes[last_name]"]')?.value || '';
    const email = this.element.querySelector('[name="constituent[email]"]')?.value ||
                  this.element.querySelector('[name="guardian_attributes[email]"]')?.value || '';
    const phone = this.element.querySelector('[name="constituent[phone]"]')?.value ||
                  this.element.querySelector('[name="guardian_attributes[phone]"]')?.value || '';
    const householdSize = this.element.querySelector('[name="application[household_size]"]')?.value || '';
    const annualIncome = this.element.querySelector('[name="application[annual_income]"]')?.value || '';

    // Set values in rejection modal hidden fields
    if (this.hasRejectionFirstNameTarget) this.rejectionFirstNameTarget.value = firstName;
    if (this.hasRejectionLastNameTarget) this.rejectionLastNameTarget.value = lastName;
    if (this.hasRejectionEmailTarget) this.rejectionEmailTarget.value = email;
    if (this.hasRejectionPhoneTarget) this.rejectionPhoneTarget.value = phone;
    if (this.hasRejectionHouseholdSizeTarget) this.rejectionHouseholdSizeTarget.value = householdSize;
    if (this.hasRejectionAnnualIncomeTarget) this.rejectionAnnualIncomeTarget.value = annualIncome;

    if (process.env.NODE_ENV !== 'production') {
      console.log('Populated rejection modal fields:', {
        firstName, lastName, email, phone, householdSize, annualIncome
      });
    }
  }
}
