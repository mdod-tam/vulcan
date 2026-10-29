import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";
import { documentUploadBlocker } from "../../utils/document_upload_state";
import {
  blockingCheckboxGroups,
  blockingRadioGroups,
  blockingRequiredControls,
  elementIsVisible as isElementVisible,
  formatIncompleteMessage,
  incompleteGroupLabels
} from "../../utils/submit_gate_state";

export default class extends Controller {
  static targets = [
    "submitButton", "rejectionButton", "status", "applicantLocale", "languagePreferenceNotice",
    "rejectionFirstName", "rejectionLastName", "rejectionRecipientId", "rejectionEmail",
    "rejectionDependentEmail", "rejectionPhone", "rejectionHouseholdSize", "rejectionAnnualIncome",
    "rejectionExistingPreferenceNotice", "rejectionExistingPreferenceValue"
  ];

  connect() {
    this._incomeExceedsThreshold = false;
    this._boundIncome = this.handleIncomeValidation.bind(this);
    this._boundSync = this.syncFormState.bind(this);
    this._boundScanStatus = this._applySubmitGating.bind(this);
    this.element.addEventListener("income-validation:validated", this._boundIncome);
    this.element.addEventListener("input", this._boundSync);
    this.element.addEventListener("change", this._boundSync);
    this.element.addEventListener("document-upload:status", this._boundScanStatus);
    this.updateLanguagePreferenceNotices();
    requestAnimationFrame(() => this.syncFormState());
  }

  disconnect() {
    this.element.removeEventListener("income-validation:validated", this._boundIncome);
    this.element.removeEventListener("input", this._boundSync);
    this.element.removeEventListener("change", this._boundSync);
    this.element.removeEventListener("document-upload:status", this._boundScanStatus);
  }

  applicantLocaleTargetConnected() { this.updateLanguagePreferenceNotices(); }

  handleIncomeValidation(event) {
    this._incomeExceedsThreshold = !!event.detail.exceedsThreshold;
    this._applySubmitGating();
  }

  syncAdultVerificationGate() { this._applySubmitGating(); }

  beforeSubmit() {
    const root = this.element.querySelector("[data-controller~='adult-picker']");
    const picker = root && this.application.getControllerForElementAndIdentifier(root, "adult-picker");
    picker?.highlightChanges();
  }

  _adultVerificationBlocksSubmit() {
    const idInput = this.element.querySelector('[name="existing_constituent_id"]');
    if (!idInput || idInput.disabled || !String(idInput.value || "").trim()) return false;

    const checkbox = this.element.querySelector(
      'input[type="checkbox"][name="contact_info_verified"][data-adult-picker-target="verificationCheckbox"]'
    );
    if (!checkbox || checkbox.disabled) return false;

    return !checkbox.checked;
  }

  /**
   * @private
   */
  _applySubmitGating() {
    const incomeBlocks = !!this._incomeExceedsThreshold;
    const verifyBlocks = this._adultVerificationBlocksSubmit();
    const requiredControlBlocks = this._requiredControlsBlockSubmit();
    const proofActionBlocks = this._requiredRadioGroupBlocksSubmit();
    const checkboxGroupBlocks = this._checkboxGroupBlocksSubmit();
    const guardianSelectionBlocks = this._guardianSelectionBlocksSubmit();
    const uploadBlocker = documentUploadBlocker(this.element, field => this.elementIsVisible(field));
    const disable = incomeBlocks || verifyBlocks || requiredControlBlocks || proofActionBlocks ||
      checkboxGroupBlocks || uploadBlocker !== null || guardianSelectionBlocks;

    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = disable;
      this.submitButtonTarget.setAttribute("aria-disabled", disable ? "true" : "false");
      if (disable) {
        this.submitButtonTarget.setAttribute("disabled", "disabled");
      } else {
        this.submitButtonTarget.removeAttribute("disabled");
      }
    }

    if (this.hasStatusTarget) {
      const message = uploadBlocker?.validationMessage || (guardianSelectionBlocks
        ? "Select or create a guardian before submitting this dependent's application."
        : (disable
          ? this._incompleteMessage()
          : "Paper application is ready to submit."));
      if (this.statusTarget.textContent !== message) this.statusTarget.textContent = message;
    }

    if (this.hasRejectionButtonTarget) {
      setVisible(this.rejectionButtonTarget, incomeBlocks);
    } else if (incomeBlocks) {
      console.warn("Missing rejectionButton target - check HTML structure");
    }
  }

  _guardianSelectionBlocksSubmit() {
    const type = this.element.querySelector('[name="applicant_type"]:checked');
    if (type?.value !== "dependent") return false;

    const guardian = this.element.querySelector('[name="guardian_id"]');
    return !String(guardian?.value || "").trim();
  }

  /**
   * Hides provider fields and removes their required state when the no-provider option is selected.
   */
  toggleCertifyingProfessional(event) {
    this.syncFormState(event);
  }

  syncFormState(event = null) {
    this.syncCertifyingProfessionalRequirement(event);
    this._applySubmitGating();
  }

  syncCertifyingProfessionalRequirement(event = null) {
    if (event?.target && !this._isCertifyingProfessionalControl(event.target)) return;

    const checkbox = this.element.querySelector('input[name="no_certifying_professional_information"]');
    if (!checkbox) return;

    const fieldset = checkbox.closest('fieldset');
    if (!fieldset) return;

    const isChecked = checkbox.checked;
    const certifyingProfessionalFields = Array.from(fieldset.querySelectorAll('input, select, textarea'))
      .filter((field) => field.name?.startsWith("application[certifying_professional_"));
    const requiredProviderFields = Array.from(certifyingProfessionalFields)
      .filter((field) => this._isApplicationCertifyingProfessionalField(field));
    const hasProviderInfo = certifyingProfessionalFields
      .some((field) => String(field.value || "").trim() !== "");
    const description = fieldset.querySelector('p.text-sm');
    const fieldsContainer = fieldset.querySelector('.grid');
    const disabilityInformationRelease = fieldset.querySelector('input[type="checkbox"][name="application[disability_information_release_authorized]"]');

    if (isChecked) {
      if (description) description.classList.add('hidden');
      if (fieldsContainer) fieldsContainer.classList.add('hidden');

      this._setRequired(requiredProviderFields, false);
      this._setRequired([disabilityInformationRelease], false);
      checkbox.required = false;
      checkbox.setCustomValidity("");
      return;
    }

    if (description) description.classList.remove('hidden');
    if (fieldsContainer) fieldsContainer.classList.remove('hidden');

    this._setRequired(requiredProviderFields, hasProviderInfo);
    this._setRequired([disabilityInformationRelease], hasProviderInfo);
    checkbox.required = !hasProviderInfo;
    checkbox.setCustomValidity(hasProviderInfo ? "" : "Check this box if no certifying professional information was provided.");
  }

  _isApplicationCertifyingProfessionalField(field) {
    return field.name.startsWith("application[certifying_professional_") && !field.name.includes("fax");
  }

  _isCertifyingProfessionalControl(field) {
    return field.name === "no_certifying_professional_information" ||
      field.name?.startsWith("application[certifying_professional_");
  }

  _setRequired(fields, required) {
    fields.filter(Boolean).forEach((field) => {
      if (required) {
        field.setAttribute('required', 'required');
        field.setAttribute('aria-required', 'true');
      } else {
        field.removeAttribute('required');
        field.removeAttribute('aria-required');
      }
    });
  }

  _requiredControlsBlockSubmit() {
    return this._blockingRequiredControls().length > 0;
  }

  _requiredRadioGroupBlocksSubmit() {
    return this._blockingRadioGroups().length > 0;
  }

  _checkboxGroupBlocksSubmit() {
    return this._blockingCheckboxGroups().length > 0;
  }

  _blockingRequiredControls() {
    return blockingRequiredControls(this.element, (field) => this.elementIsVisible(field));
  }

  _blockingRadioGroups() {
    return blockingRadioGroups(this.element, (field) => this.elementIsVisible(field));
  }

  _blockingCheckboxGroups() {
    return blockingCheckboxGroups(this.element, (field) => this.elementIsVisible(field));
  }

  // Names every blocking requirement the admin can see, so a disabled submit button never
  // leaves staff hunting across this long form for the missing item (for example the
  // disability information release under Certifying Professional Information).
  _incompleteMessage() {
    const base = "Complete all required confirmations before submitting.";

    return formatIncompleteMessage(
      base,
      "Still needed: %{items}.",
      incompleteGroupLabels(this.element, (field) => this.elementIsVisible(field))
    );
  }

  /**
   * Copies form values into the rejection modal and opens it.
   * Native <dialog> uses showModal() for modal focus behavior.
   */
  openRejectionModal() {
    const dialog = document.getElementById('rejection-modal');
    if (!dialog) {
      console.error('Rejection modal not found');
      return;
    }

    this._populateRejectionModalFields();

    if (dialog.tagName === 'DIALOG') {
      dialog.showModal();
    } else {
      console.warn('rejection-modal is not a <dialog> element');
      setVisible(dialog, true);
    }
  }

  updateLanguagePreferenceNotices() {
    if (!this.hasLanguagePreferenceNoticeTarget) return;

    const locale = this.currentApplicantLocale();
    const message = locale === 'es'
      ? 'Applicant prefers to receive Spanish communications. Please ensure any custom rejection reason is translated.'
      : 'Applicant prefers to receive English communications.';

    this.languagePreferenceNoticeTargets.forEach((target) => {
      target.textContent = message;
    });
  }

  currentApplicantLocale() {
    if (!this.hasApplicantLocaleTarget) return 'en';

    const visibleSelect = this.applicantLocaleTargets.find((target) => this.elementIsVisible(target));
    if (visibleSelect && visibleSelect.value) return visibleSelect.value;

    return this.applicantLocaleTargets[0]?.value || 'en';
  }

  elementIsVisible(element) {
    return isElementVisible(element);
  }

  /**
   * @private
   */
  _populateRejectionModalFields() {
    const firstName = this.element.querySelector('[name="constituent[first_name]"]')?.value ||
                      this.element.querySelector('[name="guardian_attributes[first_name]"]')?.value || '';
    const lastName = this.element.querySelector('[name="constituent[last_name]"]')?.value ||
                     this.element.querySelector('[name="guardian_attributes[last_name]"]')?.value || '';
    const dependentEmail = this.element.querySelector('[name="constituent[dependent_email]"]')?.value || '';
    const email = this.element.querySelector('[name="constituent[email]"]')?.value ||
                  dependentEmail ||
                  this.element.querySelector('[name="guardian_attributes[email]"]')?.value || '';
    const phone = this.element.querySelector('[name="constituent[phone]"]')?.value ||
                  this.element.querySelector('[name="guardian_attributes[phone]"]')?.value || '';
    const recipientId = this.element.querySelector('[name="dependent_id"]')?.value || '';
    const householdSize = this.element.querySelector('[name="application[household_size]"]')?.value || '';
    const annualIncome = this.element.querySelector('[name="application[annual_income]"]')?.value || '';

    if (this.hasRejectionFirstNameTarget) this.rejectionFirstNameTarget.value = firstName;
    if (this.hasRejectionLastNameTarget) this.rejectionLastNameTarget.value = lastName;
    if (this.hasRejectionRecipientIdTarget) this.rejectionRecipientIdTarget.value = recipientId;
    if (this.hasRejectionEmailTarget) this.rejectionEmailTarget.value = email;
    if (this.hasRejectionDependentEmailTarget) this.rejectionDependentEmailTarget.value = dependentEmail;
    if (this.hasRejectionPhoneTarget) this.rejectionPhoneTarget.value = phone;
    if (this.hasRejectionHouseholdSizeTarget) this.rejectionHouseholdSizeTarget.value = householdSize;
    if (this.hasRejectionAnnualIncomeTarget) this.rejectionAnnualIncomeTarget.value = annualIncome;

    this._loadExistingRecipientPreference({ recipientId, email });

    if (process.env.NODE_ENV !== 'production') {
      console.log('Populated rejection modal fields:', {
        firstName, lastName, recipientId, email, dependentEmail, phone, householdSize, annualIncome
      });
    }
  }

  async _loadExistingRecipientPreference({ recipientId, email }) {
    if (!this.hasRejectionExistingPreferenceNoticeTarget || !this.hasRejectionExistingPreferenceValueTarget) return;

    this.rejectionExistingPreferenceNoticeTarget.classList.add('hidden');
    this.rejectionExistingPreferenceValueTarget.textContent = '';

    if (!recipientId && !email) return;

    const query = new URLSearchParams();
    if (recipientId) query.set('id', recipientId);
    if (email) query.set('email', email.trim().toLowerCase());

    try {
      const response = await fetch(`/admin/paper_applications/recipient_preference?${query.toString()}`, {
        headers: { Accept: 'application/json' },
        credentials: 'same-origin'
      });
      if (!response.ok) return;

      const data = await response.json();
      if (!data.found) return;

      if (data.recipient_id && this.hasRejectionRecipientIdTarget) {
        this.rejectionRecipientIdTarget.value = data.recipient_id;
      }

      const preference = (data.communication_preference || '').toString().toLowerCase();
      if (!['email', 'letter'].includes(preference)) return;

      this._setNotificationPreferenceRadio(preference);

      this.rejectionExistingPreferenceValueTarget.textContent =
        preference === 'letter' ? 'Printed Letter' : 'Email';
      this.rejectionExistingPreferenceNoticeTarget.classList.remove('hidden');
    } catch (_error) {
      // Preference lookup failure must not prevent modal use.
    }
  }

  _setNotificationPreferenceRadio(preference) {
    const radio = this.element.querySelector(`input[name="communication_preference"][value="${preference}"]`);
    if (radio) radio.checked = true;
  }
}
