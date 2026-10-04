import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"
import { debounce } from "../../utils/debounce"

/**
 * Selects dependent contact fields or copies the guardian's address, email, and phone.
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
    // Keep the same handler reference for disconnect().
    this._boundHandleApplicantTypeChange = this.handleApplicantTypeChange.bind(this)

    this.debouncedApplicantTypeChange = debounce(() => this.executeApplicantTypeChange(), 20)

    if (this.hasSameAddressCheckboxTarget) {
      const checkbox = this.sameAddressCheckboxTarget
      if (this.hasAddressFieldsTarget) {
        this.toggleContactFields({ target: checkbox })
      }
    }

    if (this.hasSameEmailCheckboxTarget) {
      const checkbox = this.sameEmailCheckboxTarget
      if (this.hasDependentEmailTarget) {
        this.toggleEmailField({ target: checkbox })
      }
    }

    if (this.hasSamePhoneCheckboxTarget) {
      const checkbox = this.samePhoneCheckboxTarget
      if (this.hasDependentPhoneTarget) {
        this.togglePhoneField({ target: checkbox })
      }
    }

    this.formElement = this.element.closest("form")
    if (this.formElement) {
      this.formElement.addEventListener(
        "applicant-type:applicantTypeChanged",
        this._boundHandleApplicantTypeChange
      )
    }
  }

  disconnect() {
    if (this.formElement && this._boundHandleApplicantTypeChange) {
      this.formElement.removeEventListener(
        "applicant-type:applicantTypeChanged",
        this._boundHandleApplicantTypeChange
      )
    }

    this.debouncedApplicantTypeChange?.cancel()
  }

  /**
   * Shows address fields when the checkbox is clear.
   * @param {Event} event The change event from the checkbox
   */
  toggleContactFields(event) {
    if (!this.hasAddressFieldsTarget) {
      return
    }

    const useGuardianContact = event.target.checked
    this.copyFromGuardianValue = useGuardianContact

    setVisible(this.addressFieldsTarget, !useGuardianContact, { ariaHidden: useGuardianContact })

    const requiredFields = this.addressFieldsTarget.querySelectorAll('[data-dependent-fields-required-when-visible="true"]')
    requiredFields.forEach(field => {
      setVisible(field, !useGuardianContact, { required: !useGuardianContact })
    })

    if (useGuardianContact) {
      this.copyGuardianAddressInfo()
    }
  }

  /**
   * Shows the dependent email field when the checkbox is clear.
   * @param {Event} event The change event from the checkbox
   */
  toggleEmailField(event) {
    const useGuardianEmail = event.target.checked

    if (!this.hasDependentEmailTarget) return

    setVisible(this.dependentEmailTarget, !useGuardianEmail)

    if (this.hasEmailFieldContainerTarget) {
      setVisible(this.emailFieldContainerTarget, !useGuardianEmail, { ariaHidden: useGuardianEmail })
    }

    if (useGuardianEmail) {
      this.copyGuardianEmail()
    }
  }

  /**
   * Shows the dependent phone field when the checkbox is clear.
   * @param {Event} event The change event from the checkbox
   */
  togglePhoneField(event) {
    const useGuardianPhone = event.target.checked

    if (!this.hasDependentPhoneTarget) return

    setVisible(this.dependentPhoneTarget, !useGuardianPhone)

    if (this.hasPhoneFieldContainerTarget) {
      setVisible(this.phoneFieldContainerTarget, !useGuardianPhone, { ariaHidden: useGuardianPhone })
    }

    if (useGuardianPhone) {
      this.copyGuardianPhone()
    }
  }

  copyGuardianAddressInfo() {
    const hasMinAddressTargets = this.hasGuardianAddress1Target &&
      this.hasDependentAddress1Target &&
      this.hasGuardianCityTarget &&
      this.hasDependentCityTarget &&
      this.hasGuardianStateTarget &&
      this.hasDependentStateTarget &&
      this.hasGuardianZipTarget &&
      this.hasDependentZipTarget;

    if (!hasMinAddressTargets) {

      // Some forms omit address targets.
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

    this.dependentAddress1Target.value = this.guardianAddress1Target.value || '';
    this.dependentAddress2Target.value = this.guardianAddress2Target.value || '';
    this.dependentCityTarget.value = this.guardianCityTarget.value || '';
    this.dependentStateTarget.value = this.guardianStateTarget.value || 'MD';
    this.dependentZipTarget.value = this.guardianZipTarget.value || '';
  }

  copyGuardianEmail() {
    if (!this.hasGuardianEmailTarget || !this.hasDependentEmailTarget) {
      if (process.env.NODE_ENV !== 'production' && this.element.offsetParent !== null) {
        console.debug("Guardian/dependent email fields not found - using fallback");
      }
      return;
    }

    const guardianEmail = this.guardianEmailTarget.value || '';
    this.dependentEmailTarget.value = guardianEmail;
  }

  copyGuardianPhone() {
    if (!this.hasGuardianPhoneTarget || !this.hasDependentPhoneTarget) {
      if (process.env.NODE_ENV !== 'production' && this.element.offsetParent !== null) {
        console.debug("Guardian/dependent phone fields not found - using fallback");
      }
      return;
    }

    const guardianPhone = this.guardianPhoneTarget.value || '';
    this.dependentPhoneTarget.value = guardianPhone;
  }

  /**
   * Defers applicant type changes through debounce.
   * @param {CustomEvent} event The applicant-type:applicantTypeChanged event
   */
  handleApplicantTypeChange(event) {
    this._pendingEvent = event;
    this.debouncedApplicantTypeChange();
  }

  executeApplicantTypeChange() {
    try {
      if (!this._pendingEvent) return;

      const isForDependent = this._pendingEvent.detail.isDependentSelected;

      setVisible(this.element, isForDependent);

      if (this.hasRelationshipTypeTarget) {
        setVisible(this.relationshipTypeTarget, true, { required: isForDependent });
      }

      // Restore contact choices after the dependent section becomes visible.
      if (isForDependent) {
        if (this.hasSameEmailCheckboxTarget && this.hasDependentEmailTarget) {
          this.toggleEmailField({ target: this.sameEmailCheckboxTarget });
        }

        if (this.hasSamePhoneCheckboxTarget && this.hasDependentPhoneTarget) {
          this.togglePhoneField({ target: this.samePhoneCheckboxTarget });
        }

        if (this.hasSameAddressCheckboxTarget && this.hasAddressFieldsTarget) {
          this.toggleContactFields({ target: this.sameAddressCheckboxTarget });
        }
      }

    } catch (error) {
      console.error("DependentFieldsController: Error in executeApplicantTypeChange:", error);
    }
  }
}


export default DependentFieldsController
