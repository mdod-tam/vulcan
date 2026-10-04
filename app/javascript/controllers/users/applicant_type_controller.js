import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";
import { debounce } from "../../utils/debounce";

export default class extends Controller {
  static targets = ["radio", "adultSection", "adultSearchSection", "radioSection", "guardianSection", "sectionsForDependentWithGuardian", "commonSections", "dependentField", "stepNumber"];
  static outlets = ["guardian-picker", "adult-picker"];
  static values = {
    initialCreateNewAdult: { type: Boolean, default: false }
  }

  connect() {
    if (this._connected) return;
    this._connected = true;

    this._lastState = null;
    this.debouncedRefresh = debounce(() => this.executeRefresh(), 10);

    this._boundGuardianPickerSelectionChange = this.guardianPickerSelectionChange.bind(this);
    this._boundAdultPickerSelectionChange = this.adultPickerSelectionChange.bind(this);
    this._boundAdultPickerCreateNew = this.adultPickerCreateNew.bind(this);
    this._adultCreateNew = this.initialCreateNewAdultValue;

    this.element.addEventListener('guardian-picker:selectionChange', this._boundGuardianPickerSelectionChange);
    this.element.addEventListener('adult-picker:selectionChange', this._boundAdultPickerSelectionChange);
    this.element.addEventListener('adult-picker:createNew', this._boundAdultPickerCreateNew);

    this.refresh();
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

  /**
   * Forwards the existing-dependent card's "Change Dependent" action.
   *
   * The dependent Turbo frame sits outside guardian-picker in the paper form.
   * A direct `guardian-picker#…` action cannot reach that controller there.
   * This controller wraps the form and forwards the action through its outlet.
   * guardian-picker still owns the selection.
   *
   * The button requires the outlet. A missing outlet raises a wiring error instead of leaving an inert button.
   */
  changeDependent() {
    this.guardianPickerOutlet.changeDependent();
  }

  guardianPickerOutletConnected(_outlet, _element) {
    // Delay refresh until after this outlet callback.
    setTimeout(() => this.refresh(), 50);
  }

  guardianPickerOutletDisconnected(_outlet, _element) {
    // Delay refresh until after this outlet callback.
    setTimeout(() => this.refresh(), 50);
  }

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

  guardianPickerSelectionChange(event) {
    this.refresh();
  }

  updateApplicantTypeDisplay() {

    this.refresh();
  }

  refresh() {
    this.debouncedRefresh();
  }

  executeRefresh() {
    try {
      const guardianChosen = this.hasGuardianPickerOutlet && this.guardianPickerOutlet.selectedValue;

      const dependentRadioSelected = this.isDependentRadioChecked();

      if (this.hasRadioSectionTarget) {
        setVisible(this.radioSectionTarget, !guardianChosen);
      }

      if (this.hasGuardianSectionTarget) {
        setVisible(this.guardianSectionTarget, dependentRadioSelected);
        this._toggleFormFieldsDisabled(this.guardianSectionTarget, !dependentRadioSelected);
      }

      const showDependentSections = dependentRadioSelected && guardianChosen;
      if (this.hasSectionsForDependentWithGuardianTarget) {
        setVisible(this.sectionsForDependentWithGuardianTarget, showDependentSections);
        this._toggleFormFieldsDisabled(this.sectionsForDependentWithGuardianTarget, !showDependentSections);
      }

      if (this.hasDependentFieldTargets) {
        this.dependentFieldTargets.forEach(field => {
          setVisible(field, true, { required: showDependentSections });
        });
      }

      const adultRadioSelected = !dependentRadioSelected && !guardianChosen;
      const adultChosen = this.hasAdultPickerOutlet && this.adultPickerOutlet.selectedValue;

      if (this.hasAdultSearchSectionTarget) {
        setVisible(this.adultSearchSectionTarget, adultRadioSelected);
        this._toggleFormFieldsDisabled(this.adultSearchSectionTarget, !adultRadioSelected);
      }

      const showAdultInfo = adultRadioSelected && (adultChosen || this._adultCreateNew);
      if (this.hasAdultSectionTarget) {
        setVisible(this.adultSectionTarget, showAdultInfo);
        this._toggleFormFieldsDisabled(this.adultSectionTarget, !showAdultInfo);
        if (showAdultInfo) {
          this._resyncContactFeedback(this.adultSectionTarget);
        }
      }

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

      const showCommon = showAdultInfo || (dependentRadioSelected && guardianChosen);
      if (this.hasCommonSectionsTarget) {
        setVisible(this.commonSectionsTarget, showCommon);
      }

      this._updateStepNumbers();

      const currentIsDependentSelected = this.isDependentRadioChecked(); // selectRadio can change the selection above.
      const stateChanged = !this._lastState ||
        this._lastState.isDependentSelected !== currentIsDependentSelected ||
        this._lastState.guardianChosen !== guardianChosen ||
        this._lastState.showCommon !== showCommon;

      if (stateChanged) {
        this.dispatch("applicantTypeChanged", { detail: { isDependentSelected: currentIsDependentSelected } });

        this._lastState = { isDependentSelected: currentIsDependentSelected, guardianChosen, showCommon };
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
   * Sets the disabled state for fields in a section.
   * Hidden branches need disabled fields to prevent conflicting submitted values.
   * @param {HTMLElement} section - The section with form fields
   * @param {boolean} disabled - Whether to disable the fields
   * @private
   */
  _toggleFormFieldsDisabled(section, disabled) {
    if (!section) return;

    const formFields = section.querySelectorAll('input, select, textarea');

    formFields.forEach(field => {
      if (field.dataset.contactFeedbackSuppressed === 'true') return

      if (disabled) {
        field.disabled = true;
        field.setAttribute('disabled', 'disabled');
      } else {
        field.disabled = false;
        field.removeAttribute('disabled');
      }
    });
  }

  _resyncContactFeedback(section) {
    if (!section) return

    section.querySelectorAll('[data-controller~="contact-feedback"]').forEach((element) => {
      const controller = this.application.getControllerForElementAndIdentifier(element, 'contact-feedback')
      controller?.resyncNoContactState?.()
    })
  }

  /**
   * Sets step numbers in the common sections.
   * @private
   */
  _updateStepNumbers() {
    if (!this.hasStepNumberTargets || this.stepNumberTargets.length === 0) {
      return;
    }

    try {
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
