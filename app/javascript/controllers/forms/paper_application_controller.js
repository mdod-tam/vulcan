import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";

export default class extends Controller {
  static targets = [
    "submitButton", "rejectionButton", "status", "applicantLocale", "languagePreferenceNotice",
    "rejectionFirstName", "rejectionLastName", "rejectionRecipientId", "rejectionEmail",
    "rejectionDependentEmail", "rejectionPhone", "rejectionHouseholdSize", "rejectionAnnualIncome",
    "rejectionExistingPreferenceNotice", "rejectionExistingPreferenceValue"
  ];

  connect() {
    this._incomeExceedsThreshold = false;
    this._uploading = false;
    this._boundIncome = this.handleIncomeValidation.bind(this);
    this._boundSync = this.syncFormState.bind(this);
    this._boundUploadStart = () => { this._uploading = true; this._applySubmitGating(); };
    this._boundUploadEnd = () => { this._uploading = false; this._applySubmitGating(); };
    this.element.addEventListener("income-validation:validated", this._boundIncome);
    this.element.addEventListener("input", this._boundSync);
    this.element.addEventListener("change", this._boundSync);
    this.element.addEventListener("direct-uploads:start", this._boundUploadStart);
    this.element.addEventListener("direct-uploads:end", this._boundUploadEnd);
    this.updateLanguagePreferenceNotices();
    requestAnimationFrame(() => this.syncFormState());
  }

  disconnect() {
    this.element.removeEventListener("income-validation:validated", this._boundIncome);
    this.element.removeEventListener("input", this._boundSync);
    this.element.removeEventListener("change", this._boundSync);
    this.element.removeEventListener("direct-uploads:start", this._boundUploadStart);
    this.element.removeEventListener("direct-uploads:end", this._boundUploadEnd);
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
    const disable = incomeBlocks || verifyBlocks || requiredControlBlocks || proofActionBlocks ||
      checkboxGroupBlocks || this._uploading || guardianSelectionBlocks;

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
      this.statusTarget.textContent = this._uploading ? "Uploading documents…" : (guardianSelectionBlocks
        ? "Select or create a guardian before submitting this dependent's application."
        : (disable
          ? "Complete all required confirmations before submitting."
          : "Paper application is ready to submit."));
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
   * Toggle medical provider fields visibility and required attribute
   * When "No medical provider information provided" is checked, hide fields and remove required
   */
  toggleMedicalProvider(event) {
    this.syncFormState(event);
  }

  syncFormState(event = null) {
    this.syncMedicalProviderRequirement(event);
    this._applySubmitGating();
  }

  syncMedicalProviderRequirement(event = null) {
    if (event?.target && !this._isMedicalProviderControl(event.target)) return;

    const checkbox = this.element.querySelector('input[name="no_medical_provider_information"]');
    if (!checkbox) return;

    const fieldset = checkbox.closest('fieldset');
    if (!fieldset) return;

    const isChecked = checkbox.checked;
    const medicalProviderFields = Array.from(fieldset.querySelectorAll('input, select, textarea'))
      .filter((field) => field.name?.startsWith("application[medical_provider_"));
    const requiredProviderFields = Array.from(medicalProviderFields)
      .filter((field) => this._isApplicationMedicalProviderField(field));
    const hasProviderInfo = medicalProviderFields
      .some((field) => String(field.value || "").trim() !== "");
    const description = fieldset.querySelector('p.text-sm');
    const fieldsContainer = fieldset.querySelector('.grid');
    const medicalRelease = fieldset.querySelector('input[type="checkbox"][name="application[medical_release_authorized]"]');

    if (isChecked) {
      if (description) description.classList.add('hidden');
      if (fieldsContainer) fieldsContainer.classList.add('hidden');

      this._setRequired(requiredProviderFields, false);
      this._setRequired([medicalRelease], false);
      checkbox.required = false;
      checkbox.setCustomValidity("");
      return;
    }

    if (description) description.classList.remove('hidden');
    if (fieldsContainer) fieldsContainer.classList.remove('hidden');

    this._setRequired(requiredProviderFields, hasProviderInfo);
    this._setRequired([medicalRelease], hasProviderInfo);
    checkbox.required = !hasProviderInfo;
    checkbox.setCustomValidity(hasProviderInfo ? "" : "Check this box if no certifying professional information was provided.");
  }

  _isApplicationMedicalProviderField(field) {
    return field.name.startsWith("application[medical_provider_") && !field.name.includes("fax");
  }

  _isMedicalProviderControl(field) {
    return field.name === "no_medical_provider_information" ||
      field.name?.startsWith("application[medical_provider_");
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
    return this._enabledVisibleFields('input[type="checkbox"][required]')
      .concat(this._enabledVisibleFields(
        'input[required]:not([type="checkbox"]):not([type="radio"]):not([type="hidden"]):not([type="submit"]):not([type="button"]):not([type="reset"]), select[required], textarea[required]'
      ))
      .some((field) => this._fieldInvalid(field));
  }

  _requiredRadioGroupBlocksSubmit() {
    const radios = this._enabledVisibleFields('input[type="radio"][required]');
    const names = [...new Set(radios.map((radio) => radio.name).filter(Boolean))];

    return names.some((name) => {
      const group = radios.filter((radio) => radio.name === name);
      return group.length > 0 && !group.some((radio) => radio.checked);
    });
  }

  _checkboxGroupBlocksSubmit() {
    return Array.from(this.element.querySelectorAll("[data-requires-one-checkbox]"))
      .filter((group) => this.elementIsVisible(group))
      .some((group) => {
        const checkboxes = Array.from(group.querySelectorAll('input[type="checkbox"]'))
          .filter((field) => !field.disabled && this.elementIsVisible(field));
        return checkboxes.length > 0 && !checkboxes.some((field) => field.checked);
      });
  }

  _enabledVisibleFields(selector) {
    return Array.from(this.element.querySelectorAll(selector))
      .filter((field) => !field.disabled && this.elementIsVisible(field));
  }

  _fieldInvalid(field) {
    if ((field.type || "").toLowerCase() === "file") {
      return field.required && (!field.files || field.files.length === 0);
    }

    if (typeof field.checkValidity === "function") {
      return !field.checkValidity();
    }

    return String(field.value || "").trim() === "";
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
    return !!(element.offsetParent || element.getClientRects().length);
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
      // Non-blocking enhancement: keep modal functional even if lookup fails.
    }
  }

  _setNotificationPreferenceRadio(preference) {
    const radio = this.element.querySelector(`input[name="communication_preference"][value="${preference}"]`);
    if (radio) radio.checked = true;
  }
}
