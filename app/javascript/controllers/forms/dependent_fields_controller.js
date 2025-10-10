import { Controller } from "@hotwired/stimulus"
import { applyTargetSafety } from "../../mixins/target_safety"
import { setVisible } from "../../utils/visibility"
import { createFormChangeDebounce } from "../../utils/debounce"

/**
 * Controller for managing dependent-related fields
 * 
 * Responsible for toggling dependent contact information visibility and handling
 * the "Same as Guardian's" functionality for address, email, and phone.
 */
class DependentFieldsController extends Controller {
  static targets = [
    "fields",
    "addressFields",
    "sameAddressCheckbox",
    "sameEmailCheckbox",
    "samePhoneCheckbox",
    "relationshipType",
    "emailFieldContainer",
    "phoneFieldContainer",
    "dependentEmail",
    "dependentPhone",
    "guardianEmail",
    "guardianPhone",
    "guardianAddress1",
    "guardianAddress2",
    "guardianCity",
    "guardianState",
    "guardianZip",
    "dependentAddress1",
    "dependentAddress2",
    "dependentCity",
    "dependentState",
    "dependentZip"
  ]

  
  static values = {
    copyFromGuardian: Boolean
  }

  connect() {
    // Store bound method reference for proper cleanup
    this._boundHandleApplicantTypeChange = this.handleApplicantTypeChange.bind(this)

    // Set up debounced applicant type change handler
    this.debouncedApplicantTypeChange = createFormChangeDebounce(() => this.executeApplicantTypeChange())

    // Set initial state based on checkboxes if available - use target safety
    this.withTarget('sameAddressCheckbox', (checkbox) => {
      if (this.hasAddressFieldsTarget) {
        this.toggleContactFields({ target: checkbox })
      }
    })

    this.withTarget('sameEmailCheckbox', (checkbox) => {
      if (this.hasDependentEmailTarget) {
        this.toggleEmailField({ target: checkbox })
      }
    })

    this.withTarget('samePhoneCheckbox', (checkbox) => {
      if (this.hasDependentPhoneTarget) {
        this.togglePhoneField({ target: checkbox })
      }
    })

    // Listen for applicant-type change events from ApplicantTypeController
    this.formElement = this.element.closest("form")
    if (this.formElement) {
      this.formElement.addEventListener(
        "applicant-type:applicantTypeChanged",
        this._boundHandleApplicantTypeChange
      )
    }
  }

  disconnect() {
    // Clean up event listeners
    if (this.formElement && this._boundHandleApplicantTypeChange) {
      this.formElement.removeEventListener(
        "applicant-type:applicantTypeChanged",
        this._boundHandleApplicantTypeChange
      )
    }

    // Clean up debounced function
    this.debouncedApplicantTypeChange?.cancel()
  }

  /**
   * Toggle address fields based on "Same as Guardian's Address" checkbox
   * @param {Event} event The change event from the checkbox
   */
  toggleContactFields(event) {
    if (!this.hasRequiredTargets('addressFields')) {
      return
    }

    const useGuardianContact = event.target.checked
    this.copyFromGuardianValue = useGuardianContact

    // Use utility to toggle visibility and required state for the container
    setVisible(this.addressFieldsTarget, !useGuardianContact)

    // Handle required attributes for individual input fields within the container
    const inputFields = this.addressFieldsTarget.querySelectorAll('input')
    inputFields.forEach(field => {
      setVisible(field, !useGuardianContact, { required: !useGuardianContact })
    })

    // Copy guardian contact info if needed
    if (useGuardianContact) {
      this.copyGuardianAddressInfo()
    }
  }

  /**
   * Toggle dependent email field based on "Use Guardian's Email" checkbox
   * @param {Event} event The change event from the checkbox
   */
  toggleEmailField(event) {
    const useGuardianEmail = event.target.checked;

    if (!this.hasDependentEmailTarget) return;

    // Use utility to handle email field visibility and required state
    setVisible(this.dependentEmailTarget, !useGuardianEmail, { required: !useGuardianEmail });

    // Handle email field container visibility if available
    if (this.hasEmailFieldContainerTarget) {
      setVisible(this.emailFieldContainerTarget, !useGuardianEmail);
    }

    // Copy guardian's email if needed
    if (useGuardianEmail) {
      this.copyGuardianEmail()
    }
  }

  /**
   * Toggle dependent phone field based on "Use Guardian's Phone" checkbox
   * @param {Event} event The change event from the checkbox
   */
  togglePhoneField(event) {
    const useGuardianPhone = event.target.checked;

    if (!this.hasDependentPhoneTarget) return;

    // Use utility to handle phone field visibility and required state
    setVisible(this.dependentPhoneTarget, !useGuardianPhone, { required: !useGuardianPhone });

    // Handle phone field container visibility if available
    if (this.hasPhoneFieldContainerTarget) {
      setVisible(this.phoneFieldContainerTarget, !useGuardianPhone);
    }

    // Copy guardian's phone if needed
    if (useGuardianPhone) {
      this.copyGuardianPhone()
    }
  }

  /**
   * Copy guardian's address fields to dependent fields
   */
  copyGuardianAddressInfo() {
    // Check for minimum required address fields
    const hasMinAddressTargets = this.hasGuardianAddress1Target &&
      this.hasDependentAddress1Target &&
      this.hasGuardianCityTarget &&
      this.hasDependentCityTarget &&
      this.hasGuardianStateTarget &&
      this.hasDependentStateTarget &&
      this.hasGuardianZipTarget &&
      this.hasDependentZipTarget;

    if (!hasMinAddressTargets) {

      // Copy individual fields if available
      if (this.hasGuardianAddress1Target && this.hasDependentAddress1Target) {
        this.dependentAddress1Target.value = this.guardianAddress1Target.value || '';
      }
      if (this.hasGuardianAddress2Target && this.hasDependentAddress2Target) {
        this.dependentAddress2Target.value = this.guardianAddress2Target.value || '';
      }
      if (this.hasGuardianCityTarget && this.hasDependentCityTarget) {
        this.dependentCityTarget.value = this.guardianCityTarget.value || '';
      }
      if (this.hasGuardianStateTarget && this.hasDependentStateTarget) {
        this.dependentStateTarget.value = this.guardianStateTarget.value || 'MD';
      }
      if (this.hasGuardianZipTarget && this.hasDependentZipTarget) {
        this.dependentZipTarget.value = this.guardianZipTarget.value || '';
      }
      return;
    }

    // Copy address fields
    this.dependentAddress1Target.value = this.guardianAddress1Target.value || '';
    this.dependentAddress2Target.value = this.guardianAddress2Target.value || '';
    this.dependentCityTarget.value = this.guardianCityTarget.value || '';
    this.dependentStateTarget.value = this.guardianStateTarget.value || 'MD';
    this.dependentZipTarget.value = this.guardianZipTarget.value || '';
  }

  /**
   * Copy guardian's email to dependent email field
   */
  copyGuardianEmail() {
    if (!this.hasGuardianEmailTarget || !this.hasDependentEmailTarget) {
      if (process.env.NODE_ENV !== 'production' && this.element.offsetParent !== null) {
        console.debug("Guardian/dependent email fields not found - using fallback");
      }
      return;
    }

    // Prefer guardian's email if available
    const guardianEmail = this.guardianEmailTarget.value || '';
    this.dependentEmailTarget.value = guardianEmail;
  }

  /**
   * Copy guardian's phone to dependent phone field
   */
  copyGuardianPhone() {
    if (!this.hasGuardianPhoneTarget || !this.hasDependentPhoneTarget) {
      if (process.env.NODE_ENV !== 'production' && this.element.offsetParent !== null) {
        console.debug("Guardian/dependent phone fields not found - using fallback");
      }
      return;
    }

    // Prefer guardian's phone if available
    const guardianPhone = this.guardianPhoneTarget.value || '';
    this.dependentPhoneTarget.value = guardianPhone;
  }

  /**
   * Handle applicant type change event from parent controller
   * @param {CustomEvent} event The change:applicant-type custom event
   */
  handleApplicantTypeChange(event) {
    // Store event data for debounced execution
    this._pendingEvent = event;
    this.debouncedApplicantTypeChange();
  }

  /**
   * Execute the applicant type change logic (debounced)
   */
  executeApplicantTypeChange() {
    try {
      if (!this._pendingEvent) return;

      const isForDependent = this._pendingEvent.detail.isDependentSelected;

      // Use utility to handle visibility of this controller's element
      setVisible(this.element, isForDependent);

      // Use utility to handle relationship type required state
      if (this.hasRelationshipTypeTarget) {
        setVisible(this.relationshipTypeTarget, true, { required: isForDependent });
      }

      // Re-apply checkbox states when applicant type changes
      // Only if we're showing the dependent fields AND the required targets exist
      if (isForDependent) {
        // Check for email checkbox and targets before trying to toggle
        if (this.hasSameEmailCheckboxTarget && this.hasDependentEmailTarget) {
          this.toggleEmailField({ target: this.sameEmailCheckboxTarget });
        }

        // Check for phone checkbox and targets before trying to toggle
        if (this.hasSamePhoneCheckboxTarget && this.hasDependentPhoneTarget) {
          this.togglePhoneField({ target: this.samePhoneCheckboxTarget });
        }

        // Check for address checkbox and targets before trying to toggle
        if (this.hasSameAddressCheckboxTarget && this.hasAddressFieldsTarget) {
          this.toggleContactFields({ target: this.sameAddressCheckboxTarget });
        }
      }

    } catch (error) {
      console.error("DependentFieldsController: Error in executeApplicantTypeChange:", error);
    }
  }
}

// Apply target safety mixin
applyTargetSafety(DependentFieldsController)

export default DependentFieldsController
