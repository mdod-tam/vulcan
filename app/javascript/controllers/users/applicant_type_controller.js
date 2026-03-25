import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";
import { createVeryShortDebounce } from "../../utils/debounce";

export default class extends Controller {
  static targets = ["radio", "adultSection", "adultSearchSection", "radioSection", "guardianSection", "sectionsForDependentWithGuardian", "commonSections", "dependentField", "stepNumber"];
  static outlets = ["guardian-picker", "adult-picker"];
  static values = {
    initialCreateNewAdult: { type: Boolean, default: false }
  }

  connect() {
    // Guard against multiple connections
    if (this._connected) return;
    this._connected = true;

    this._lastState = null; // Track last state to prevent unnecessary dispatches
    this.debouncedRefresh = createVeryShortDebounce(() => this.executeRefresh());

    this._boundGuardianPickerSelectionChange = this.guardianPickerSelectionChange.bind(this);
    this._boundAdultPickerSelectionChange = this.adultPickerSelectionChange.bind(this);
    this._boundAdultPickerCreateNew = this.adultPickerCreateNew.bind(this);
    this._adultCreateNew = this.initialCreateNewAdultValue; // Track "Create New Applicant" state

    this.element.addEventListener('guardian-picker:selectionChange', this._boundGuardianPickerSelectionChange);
    this.element.addEventListener('adult-picker:selectionChange', this._boundAdultPickerSelectionChange);
    this.element.addEventListener('adult-picker:createNew', this._boundAdultPickerCreateNew);

    this.refresh();
    // If the guardian picker outlet is available, observe it for changes.
    // Relying on guardianPickerOutlet.selectedValue in refresh() called by other actions is an alternative to custom events if direct observation is preferred for future Stimulus versions.
  }

  disconnect() {
    this._connected = false;
    this.debouncedRefresh?.cancel();
    this._lastState = null;

    if (this._boundGuardianPickerSelectionChange) {
      this.element.removeEventListener('guardian-picker:selectionChange', this._boundGuardianPickerSelectionChange);
    }
    if (this._boundAdultPickerSelectionChange) {
      this.element.removeEventListener('adult-picker:selectionChange', this._boundAdultPickerSelectionChange);
    }
    if (this._boundAdultPickerCreateNew) {
      this.element.removeEventListener('adult-picker:createNew', this._boundAdultPickerCreateNew);
    }
  }

  // This can be called by an action on the guardian-picker if its selection changes, or if this controller needs to react to external changes.
  guardianPickerOutletConnected(_outlet, _element) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Guardian Picker Outlet Connected");
    }
    // Use a delayed refresh to avoid immediate recursion
    setTimeout(() => this.refresh(), 50);
  }

  guardianPickerOutletDisconnected(_outlet, _element) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Guardian Picker Outlet Disconnected");
    }
    // Use a delayed refresh to avoid immediate recursion
    setTimeout(() => this.refresh(), 50);
  }

  // Adult picker outlet hooks
  adultPickerOutletConnected() {
    setTimeout(() => this.refresh(), 50);
  }

  adultPickerOutletDisconnected() {
    setTimeout(() => this.refresh(), 50);
  }

  adultPickerSelectionChange(_event) {
    this._adultCreateNew = false;
    this.refresh();
  }

  adultPickerCreateNew(_event) {
    this._adultCreateNew = true;
    this.refresh();
  }

  // Handle guardian picker selection changes
  guardianPickerSelectionChange(event) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Guardian selection changed:", event.detail);
    }
    // Refresh to update visibility based on new guardian selection
    this.refresh();
  }

  updateApplicantTypeDisplay() { // Called by radio button change
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: updateApplicantTypeDisplay fired, isDependentSelected:", this.isDependentRadioChecked());
    }
    this.refresh(); // refresh will now handle the event dispatch
  }

  refresh() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Refresh executing");
    }
    this.debouncedRefresh();
  }

  executeRefresh() {
    try {
      if (process.env.NODE_ENV !== 'production') {
        console.log("ApplicantTypeController: executeRefresh running");
      }
      // Check if guardianPickerOutlet is connected and has a value
      const guardianChosen = this.hasGuardianPickerOutlet && this.guardianPickerOutlet.selectedValue;

      // Determine if the dependent section should be shown
      // It's shown if a guardian is chosen OR if the 'dependent' radio is manually checked (and no guardian is chosen)
      const dependentRadioSelected = this.isDependentRadioChecked();

      if (process.env.NODE_ENV !== 'production') {
        console.log("ApplicantTypeController: State check:", {
          hasGuardianPickerOutlet: this.hasGuardianPickerOutlet,
          guardianPickerSelectedValue: this.hasGuardianPickerOutlet ? this.guardianPickerOutlet.selectedValue : null,
          guardianChosen: guardianChosen,
          dependentRadioSelected: dependentRadioSelected,
          showDependentSections: dependentRadioSelected && guardianChosen
        });
      }

      // Hide the applicant-type radio section when a guardian is chosen
      if (this.hasRadioSectionTarget) {
        setVisible(this.radioSectionTarget, !guardianChosen);
      }

      // Show guardian section (guardian picker) if dependent radio is selected
      if (this.hasGuardianSectionTarget) {
        setVisible(this.guardianSectionTarget, dependentRadioSelected);
        // Disable form fields in hidden guardian section to prevent form submission conflicts
        this._toggleFormFieldsDisabled(this.guardianSectionTarget, !dependentRadioSelected);
        if (process.env.NODE_ENV !== 'production') {
          console.log(`ApplicantTypeController: Guardian Section ${this.guardianSectionTarget.classList.contains("hidden") ? "hidden" : "visible"}`);
        }
      }

      // Show sections for dependent with guardian only if dependent radio is selected AND a guardian is chosen
      const showDependentSections = dependentRadioSelected && guardianChosen;
      if (this.hasSectionsForDependentWithGuardianTarget) {
        setVisible(this.sectionsForDependentWithGuardianTarget, showDependentSections);
        // Disable form fields in hidden dependent section to prevent form submission conflicts
        this._toggleFormFieldsDisabled(this.sectionsForDependentWithGuardianTarget, !showDependentSections);
        if (process.env.NODE_ENV !== 'production') {
          console.log(`ApplicantTypeController: Dependent Sections ${showDependentSections ? "SHOWN" : "HIDDEN"}`);
        }
      }

      // Manage 'required' attribute for dependent fields
      if (this.hasDependentFieldTargets) {
        this.dependentFieldTargets.forEach(field => {
          setVisible(field, true, { required: showDependentSections });
        });
      }

      // Adult flow state
      const adultRadioSelected = !dependentRadioSelected && !guardianChosen;
      const adultChosen = this.hasAdultPickerOutlet && this.adultPickerOutlet.selectedValue;

      // Show adult search section when adult radio is selected
      if (this.hasAdultSearchSectionTarget) {
        setVisible(this.adultSearchSectionTarget, adultRadioSelected);
        this._toggleFormFieldsDisabled(this.adultSearchSectionTarget, !adultRadioSelected);
      }

      // Adult info section visible when: adult selected AND (adult picked OR creating new)
      const showAdultInfo = adultRadioSelected && (adultChosen || this._adultCreateNew);
      if (this.hasAdultSectionTarget) {
        setVisible(this.adultSectionTarget, showAdultInfo);
        this._toggleFormFieldsDisabled(this.adultSectionTarget, !showAdultInfo);
      }

      // Disable radio buttons if a guardian is chosen and add title
      const radioTitle = guardianChosen ? "Guardian selected – switch enabled after clearing selection" : "";
      this.radioTargets.forEach(radio => {
        if (radio.disabled !== guardianChosen) {
          radio.disabled = guardianChosen;
        }
        if (radio.title !== radioTitle) {
          radio.title = radioTitle;
        }
      });

      if (guardianChosen) {
        this.selectRadio("dependent");
      }

      // Common sections: (adult info visible) OR (dependent-with-guardian)
      const showCommon = showAdultInfo || (dependentRadioSelected && guardianChosen);
      if (this.hasCommonSectionsTarget) {
        setVisible(this.commonSectionsTarget, showCommon);
      }

      // Both flows use baseStep=4 for common sections
      this._updateStepNumbers();

      // Only dispatch event if the meaningful state has changed
      const currentIsDependentSelected = this.isDependentRadioChecked(); // Re-check after potential selectRadio call
      const stateChanged = !this._lastState ||
        this._lastState.isDependentSelected !== currentIsDependentSelected ||
        this._lastState.guardianChosen !== guardianChosen;

      if (stateChanged) {
        if (process.env.NODE_ENV !== 'production') {
          console.log("ApplicantTypeController: Dispatching applicantTypeChanged. isDependentSelected:", currentIsDependentSelected);
        }
        this.dispatch("applicantTypeChanged", { detail: { isDependentSelected: currentIsDependentSelected } });

        // Update last state
        this._lastState = { isDependentSelected: currentIsDependentSelected, guardianChosen };
      }

    } catch (error) {
      console.error("ApplicantTypeController: Error in refresh:", error);
    }
  }

  isDependentRadioChecked() {
    const selectedRadio = this.radioTargets.find(radio => radio.checked);
    return selectedRadio?.value === "dependent";
  }

  selectRadio(value) {
    const radioToSelect = this.radioTargets.find(radio => radio.value === value);
    if (radioToSelect && !radioToSelect.checked) {
      radioToSelect.checked = true;
    }
  }

  /**
   * Toggle disabled state of form fields within a section
   * @param {HTMLElement} section - The section containing form fields
   * @param {boolean} disabled - Whether to disable the fields
   * @private
   */
  _toggleFormFieldsDisabled(section, disabled) {
    if (!section) return;

    // Find all form fields within the section
    const formFields = section.querySelectorAll('input, select, textarea');

    formFields.forEach(field => {
      if (disabled) {
        field.disabled = true;
        field.setAttribute('disabled', 'disabled');
      } else {
        field.disabled = false;
        field.removeAttribute('disabled');
      }
    });
  }

  /**
   * Update step numbers in common sections.
   * Both adult and dependent flows use baseStep=4.
   * @private
   */
  _updateStepNumbers() {
    if (!this.hasStepNumberTargets || this.stepNumberTargets.length === 0) {
      return;
    }

    try {
      // Both adult and dependent flows: common sections start at step 4
      // Adult: 1=type, 2=search, 3=info, 4+=common
      // Dependent: 1=type, 2=guardian, 3=dependent, 4+=common
      const baseStep = 4;
      this.stepNumberTargets.forEach((stepEl, index) => {
        stepEl.textContent = baseStep + index;
      });
    } catch (error) {
      console.error("ApplicantTypeController: Error updating step numbers:", error);
    }
  }
}
