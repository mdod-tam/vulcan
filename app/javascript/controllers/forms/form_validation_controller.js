import { Controller } from "@hotwired/stimulus"

/**
 * Form Validation Controller
 * 
 * Provides client-side validation for paper application forms.
 * Works in conjunction with HTML5 validation and server-side validation.
 */
export default class FormValidationController extends Controller {
  static targets = [
    "form",
    "errorContainer",
    "acceptIncomeProof",
    "rejectIncomeProof", 
    "incomeProofFile",
    "incomeProofRejectionReason",
    "acceptResidencyProof",
    "rejectResidencyProof",
    "residencyProofFile", 
    "residencyProofRejectionReason",
    "checkbox",
    "checkboxGroup",
    "validationMessage"
  ]

  static values = {
    type: String  // e.g., "disability-checkbox"
  }

  connect() {
    // Store bound method reference for proper cleanup
    this._boundValidateForm = this.validateForm.bind(this)
    
    // Set up form validation hooks
    if (this.hasFormTarget) {
      this.formTarget.addEventListener('submit', this._boundValidateForm);
    }
    
    // If this is a disability checkbox validator, set up form submission listener
    if (this.typeValue === "disability-checkbox") {
      this._boundValidateDisabilityOnSubmit = this.validateDisabilityOnSubmit.bind(this)
      const form = this.element.closest('form')
      if (form) {
        form.addEventListener('submit', this._boundValidateDisabilityOnSubmit)
      }
    }
  }

  disconnect() {
    // Clean up event listeners
    if (this.hasFormTarget) {
      this.formTarget.removeEventListener('submit', this._boundValidateForm);
    }
    
    // Clean up disability checkbox validator listener
    if (this.typeValue === "disability-checkbox" && this._boundValidateDisabilityOnSubmit) {
      const form = this.element.closest('form')
      if (form) {
        form.removeEventListener('submit', this._boundValidateDisabilityOnSubmit)
      }
    }
  }

  /**
   * Custom form validation before submission
   * @param {Event} event Form submission event
   */
  validateForm(event) {
    let isValid = true;
    const errorContainer = this.getOrCreateErrorContainer();
    
    // Clear any existing errors
    errorContainer.innerHTML = '';
    
    // Validate income proof
    isValid = this.validateProofSection('income_proof', errorContainer) && isValid;
    
    // Validate residency proof
    isValid = this.validateProofSection('residency_proof', errorContainer) && isValid;
    
    // If invalid, prevent form submission
    if (!isValid) {
      event.preventDefault();
      
      // Scroll to the error container
      errorContainer.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
    
    return isValid;
  }
  
  /**
   * Validate a proof document section
   * @param {string} proofType Type of proof (income_proof or residency_proof)
   * @param {HTMLElement} errorContainer Container for error messages
   * @returns {boolean} Whether the section is valid
   */
  validateProofSection(proofType, errorContainer) {
    let isValid = true;
    
    const isIncomeProof = proofType === 'income_proof';
    const acceptTarget = isIncomeProof ? 'acceptIncomeProofTarget' : 'acceptResidencyProofTarget';
    const rejectTarget = isIncomeProof ? 'rejectIncomeProofTarget' : 'rejectResidencyProofTarget'; 
    const fileTarget = isIncomeProof ? 'incomeProofFileTarget' : 'residencyProofFileTarget';
    const reasonTarget = isIncomeProof ? 'incomeProofRejectionReasonTarget' : 'residencyProofRejectionReasonTarget';
    
    // Convert target names to hasTarget method names
    const hasAcceptTarget = `has${acceptTarget.charAt(0).toUpperCase() + acceptTarget.slice(1)}`;
    const hasRejectTarget = `has${rejectTarget.charAt(0).toUpperCase() + rejectTarget.slice(1)}`;
    const hasFileTarget = `has${fileTarget.charAt(0).toUpperCase() + fileTarget.slice(1)}`;
    const hasReasonTarget = `has${reasonTarget.charAt(0).toUpperCase() + reasonTarget.slice(1)}`;
    
    
    // Early return if critical targets are missing - this indicates markup mismatch
    if (!this[hasAcceptTarget] && !this[hasRejectTarget]) {
      console.warn(`Missing both accept and reject targets for ${proofType} - check HTML structure`);
      this.addError(errorContainer, `Form configuration error for ${proofType.replace('_', ' ')}`);
      return false;
    }
    
    // Check if accept radio is selected
    if (this[hasAcceptTarget] && this[acceptTarget]?.checked) {
      // Verify file is uploaded
      if (this[hasFileTarget]) {
        const fileInput = this[fileTarget];
        if (!fileInput || !fileInput.files || fileInput.files.length === 0) {
          this.addError(errorContainer, `Please upload a ${proofType.replace('_', ' ')} document`);
          isValid = false;
        }
      } else {
        console.warn(`Missing file input target for ${proofType}`);
        this.addError(errorContainer, `Please upload a ${proofType.replace('_', ' ')} document`);
        isValid = false;
      }
    } 
    // Check if reject radio is selected
    else if (this[hasRejectTarget] && this[rejectTarget]?.checked) {
      // Verify rejection reason is selected
      if (this[hasReasonTarget]) {
        const reasonSelect = this[reasonTarget];
        if (!reasonSelect || !reasonSelect.value) {
          this.addError(errorContainer, `Please select a reason for rejecting ${proofType.replace('_', ' ')}`);
          isValid = false;
        }
      } else {
        console.warn(`Missing rejection reason target for ${proofType}`);
        this.addError(errorContainer, `Please select a reason for rejecting ${proofType.replace('_', ' ')}`);
        isValid = false;
      }
    } 
    // Neither accept nor reject selected
    else {
      this.addError(errorContainer, `Please select an option for ${proofType.replace('_', ' ')}`);
      isValid = false;
    }
    
    return isValid;
  }
  
  /**
   * Create or get the error container for form validation
   * @returns {HTMLElement} The error container element
   */
  getOrCreateErrorContainer() {
    if (this.hasErrorContainerTarget) {
      // Clear existing errors
      this.errorContainerTarget.innerHTML = '';
      return this.errorContainerTarget;
    }
    
    // Warn about missing target - this should be the preferred approach
    console.warn("Missing errorContainer target - falling back to class selector. Consider adding data-form-validation-target='errorContainer' to HTML");
    
    let errorContainer = this.element.querySelector('.form-error-container');
    if (!errorContainer) {
      errorContainer = document.createElement('div');
      errorContainer.className = 'form-error-container bg-red-100 border border-red-400 text-red-700 p-4 rounded mb-4';
      this.element.insertBefore(errorContainer, this.element.firstChild);
    } else {
      // Clear existing errors
      errorContainer.innerHTML = '';
    }
    return errorContainer;
  }
  
  /**
   * Add an error message to the error container
   * @param {HTMLElement} container The error container
   * @param {string} message The error message
   */
  addError(container, message) {
    const errorMessage = document.createElement('p');
    errorMessage.textContent = message;
    errorMessage.className = 'mb-1 last:mb-0';
    container.appendChild(errorMessage);
  }

  /**
   * Validate disability checkboxes in real-time
   * Shows/hides validation message as user checks/unchecks boxes
   */
  validateDisabilityCheckboxes() {
    if (!this.hasCheckboxTarget) return

    const anyChecked = this.checkboxTargets.some(checkbox => checkbox.checked)
    
    if (this.hasValidationMessageTarget) {
      if (anyChecked) {
        this.validationMessageTarget.classList.add('hidden')
        this.element.setAttribute('aria-invalid', 'false')
      } else {
        this.validationMessageTarget.classList.remove('hidden')
        this.element.setAttribute('aria-invalid', 'true')
      }
    }
  }

  /**
   * Validate disability checkboxes on form submission
   * Prevents submission if no checkboxes are selected
   * @param {Event} event Form submission event
   */
  validateDisabilityOnSubmit(event) {
    if (!this.hasCheckboxTarget) return

    const anyChecked = this.checkboxTargets.some(checkbox => checkbox.checked)
    
    if (!anyChecked) {
      event.preventDefault()
      
      // Show validation message
      if (this.hasValidationMessageTarget) {
        this.validationMessageTarget.classList.remove('hidden')
        this.element.setAttribute('aria-invalid', 'true')
      }
      
      // Focus the first checkbox for accessibility
      if (this.checkboxTargets.length > 0) {
        this.checkboxTargets[0].focus()
      }
      
      // Scroll to the fieldset
      this.element.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  }
}
