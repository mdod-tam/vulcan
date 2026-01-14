import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";
import { createVeryShortDebounce } from "../../utils/debounce";

export default class extends Controller {
  static targets = ["radio", "adultSection", "radioSection", "guardianSection", "sectionsForDependentWithGuardian", "commonSections", "dependentField", "stepNumber"];
  static outlets = ["guardian-picker"]; // Keep guardian-picker outlet

  connect() {
    // Guard against multiple connections
    if (this._connected) return;
    this._connected = true;

    this._lastState = null; // Track last state to prevent unnecessary dispatches
    this.debouncedRefresh = createVeryShortDebounce(() => this.executeRefresh());

    // Store bound method reference for cleanup
    this._boundGuardianPickerSelectionChange = this.guardianPickerSelectionChange.bind(this);

    // Listen for guardian picker selection changes
    this.element.addEventListener('guardian-picker:selectionChange', this._boundGuardianPickerSelectionChange);

    this.refresh();
    // If the guardian picker outlet is available, observe it for changes.
    // Relying on guardianPickerOutlet.selectedValue in refresh() called by other actions is an alternative to custom events if direct observation is preferred for future Stimulus versions.
  }

  disconnect() {
    this._connected = false;
    this.debouncedRefresh?.cancel();
    this._lastState = null;

    // Clean up event listener
    if (this._boundGuardianPickerSelectionChange) {
      this.element.removeEventListener('guardian-picker:selectionChange', this._boundGuardianPickerSelectionChange);
    }
  }

  // This can be called by an action on the guardian-picker if its selection changes, or if this controller needs to react to external changes.
  guardianPickerOutletConnected(outlet, element) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Guardian Picker Outlet Connected");
    }
    // Use a delayed refresh to avoid immediate recursion
    setTimeout(() => this.refresh(), 50);
  }

  guardianPickerOutletDisconnected(outlet, element) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("ApplicantTypeController: Guardian Picker Outlet Disconnected");
    }
    // Use a delayed refresh to avoid immediate recursion
    setTimeout(() => this.refresh(), 50);
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

      // Adult section is hidden if dependent flow is active (either dependent radio selected or guardian chosen)
      const showAdultSection = !dependentRadioSelected && !guardianChosen;
      if (this.hasAdultSectionTarget) {
        setVisible(this.adultSectionTarget, showAdultSection);
        // Disable form fields in hidden adult section to prevent form submission conflicts
        this._toggleFormFieldsDisabled(this.adultSectionTarget, !showAdultSection);
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

      // If a guardian is chosen, ensure the 'dependent' radio is selected
      if (guardianChosen) {
        this.selectRadio("dependent");
        // Ensure dependent info section is visible (already handled by toggle above)
        // Ensure guardian picker section is visible (already handled by toggle above, will be hidden by guardian-picker itself if needed)
      }
      // If no guardian is chosen, and dependent was auto-selected, but then user clicks "The Adult"
      // ensure dependent section is hidden. This is handled by showDependentSection logic.

      // SHOW commonSections when adult flow OR dependent-with-guardian flow
      const showCommon = (!dependentRadioSelected && !guardianChosen) || (dependentRadioSelected && guardianChosen);
      if (this.hasCommonSectionsTarget) {
        setVisible(this.commonSectionsTarget, showCommon);
      }

      // Update step numbers in common sections based on applicant type
      // Adult flow: 3, 4, 5 | Dependent flow: 4, 5, 6 (because step 3 is Dependent Information)
      this._updateStepNumbers(showDependentSections);

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
   * Update step numbers in common sections based on applicant type
   * @param {boolean} isDependentFlow - Whether the dependent flow is active
   * @private
   */
  _updateStepNumbers(isDependentFlow) {
    if (!this.hasStepNumberTargets || this.stepNumberTargets.length === 0) {
      return;
    }

    try {
      // Adult flow: 3, 4, 5 | Dependent flow: 4, 5, 6
      const baseStep = isDependentFlow ? 4 : 3;
      this.stepNumberTargets.forEach((stepEl, index) => {
        stepEl.textContent = baseStep + index;
      });
    } catch (error) {
      console.error("ApplicantTypeController: Error updating step numbers:", error);
    }
  }
}
