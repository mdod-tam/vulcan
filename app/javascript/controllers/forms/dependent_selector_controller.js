import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

/**
 * Dependent Selector Controller
 * 
 * Manages dependent selection in application forms,
 * including showing/hiding dependent selection UI and updating form titles.
 */
export default class extends Controller {
  static targets = [
    "dependentSection",
    "dependentSelect",
    "formTitle",
    "applyDependentRadio",
    "applySelfRadio"
  ]

  static values = {
    userId: String
  }

  connect() {

    // Guard against multiple connections
    if (this._initialized) return;
    this._initialized = true;

    // Read initial state from DOM
    this._isForSelf = this.hasApplySelfRadioTarget ? this.applySelfRadioTarget.checked : true;

    // Initialize from URL parameters only if they exist
    const urlParams = new URLSearchParams(window.location.search)
    const hasUrlParams = urlParams.has('for_self') || urlParams.has('user_id')

    if (hasUrlParams) {
      this.initializeDependentSelection();
    }
  }

  disconnect() {
    this._cleanupListeners();
    this._initialized = false;
  }

  // Toggle dependent selection visibility based on radio button selection
  toggleDependentSelection(event) {

    if (!this.hasDependentSectionTarget) {
      return;
    }

    const isForSelf = event.target.value === "true";
    this._isForSelf = isForSelf;

    if (isForSelf) {
      this.hideDependentSection();
      this.updateFormTitle("New Application");
    } else {
      this.showDependentSection();
      this.updateFormTitle("New Application");
    }

    // Dispatch event for other controllers to listen to
    this.dispatch("selectionChanged", {
      detail: { isForSelf, target: event.target }
    });
  }

  // Alias for toggleDependentSelection to match the action name in the view
  toggleAction(event) {
    this.toggleDependentSelection(event);
  }

  // Alias for updateDependentName to match the action name in the view
  selectDependentAction(event) {
    this.updateDependentName();
  }

  // Update form title when dependent selection changes
  updateDependentName() {
    this.updateFormTitleFromSelection();

    // Dispatch event with selected dependent info
    if (this.hasDependentSelectTarget && this.dependentSelectTarget.value) {
      const selectedOption = this.dependentSelectTarget.options[this.dependentSelectTarget.selectedIndex];

      this.dispatch("dependentSelected", {
        detail: {
          dependentId: this.dependentSelectTarget.value,
          dependentName: selectedOption.text
        }
      });
    }
  }

  showDependentSection() {
    setVisible(this.dependentSectionTarget, true, { required: true });
  }

  hideDependentSection() {
    setVisible(this.dependentSectionTarget, false);

    if (this.hasDependentSelectTarget) {
      this.dependentSelectTarget.removeAttribute("required");
      this.dependentSelectTarget.value = "";
    }
  }

  // Helper to ensure listener is set up correctly without duplicates
  _ensureListener() {
    if (!this.hasDependentSelectTarget) return;

    // Create bound method if it doesn't exist
    if (!this._boundUpdateDependentName) {
      this._boundUpdateDependentName = this.updateDependentName.bind(this);
    }

    // Remove existing listener (if any) and add new one
    this.dependentSelectTarget.removeEventListener("change", this._boundUpdateDependentName);
    this.dependentSelectTarget.addEventListener("change", this._boundUpdateDependentName);
  }

  // Clean up event listeners
  _cleanupListeners() {
    if (this._boundUpdateDependentName && this.hasDependentSelectTarget) {
      this.dependentSelectTarget.removeEventListener('change', this._boundUpdateDependentName);
    }
  }

  updateFormTitleFromSelection() {
    if (!this.hasDependentSelectTarget) {
      return;
    }

    if (this.dependentSelectTarget.value) {
      const selectedOption = this.dependentSelectTarget.options[this.dependentSelectTarget.selectedIndex]
      const dependentName = selectedOption.text
      this.updateFormTitle(`New Application for ${dependentName}`)
    } else {
      this.updateFormTitle("New Application")
    }
  }

  updateFormTitle(title) {
    if (!this.hasFormTitleTarget) {
      console.warn("Missing formTitle target - check HTML structure");
      return;
    }
    this.formTitleTarget.textContent = title;
  }

  // Initialize dependent selection based on URL parameters or existing state
  initializeDependentSelection() {
    const urlParams = new URLSearchParams(window.location.search)
    const forSelfParam = urlParams.get('for_self')
    const userIdParam = urlParams.get('user_id')

    // Determine if this should be a dependent application
    const isForDependent = this.shouldInitializeForDependent(forSelfParam, userIdParam)

    if (isForDependent) {
      this.initializeDependentApplication(userIdParam)
    } else {
      this.initializeSelfApplication()
    }

    // After initialization, the Stimulus action binding will handle events
  }

  shouldInitializeForDependent(forSelfParam, userIdParam) {
    return forSelfParam === 'false' || userIdParam !== null
  }

  initializeDependentApplication(userIdParam) {
    // Use targets consistently - no fallbacks
    if (!this.hasApplyDependentRadioTarget) {
      console.warn("Missing applyDependentRadio target - check HTML structure");
      return;
    }

    this.applyDependentRadioTarget.checked = true;
    this._isForSelf = false;
    this.showDependentSection();

    // Set specific dependent if provided in URL
    if (userIdParam && this.hasDependentSelectTarget) {
      this.selectDependentById(userIdParam)
    }

    this.updateFormTitleFromSelection();
  }

  initializeSelfApplication() {
    // Use targets consistently - no fallbacks
    if (!this.hasApplySelfRadioTarget) {
      console.warn("Missing applySelfRadio target - check HTML structure");
      return;
    }

    this.applySelfRadioTarget.checked = true;
    this._isForSelf = true;

    if (this.hasDependentSectionTarget) {
      this.hideDependentSection();
    }

    this.updateFormTitle("New Application");
  }

  selectDependentById(userId) {
    if (!this.hasDependentSelectTarget) return

    // Find and select the option with matching user ID
    Array.from(this.dependentSelectTarget.options).forEach(option => {
      if (option.value === userId) {
        this.dependentSelectTarget.value = userId
      }
    })

    // Update title after selection
    this.updateFormTitleFromSelection()
  }

  // Public API for other controllers
  getCurrentSelection() {
    return {
      isForSelf: this._isForSelf,
      dependentId: this.hasDependentSelectTarget ? this.dependentSelectTarget.value : null,
      dependentName: this.getSelectedDependentName()
    }
  }

  getSelectedDependentName() {
    if (!this.hasDependentSelectTarget || !this.dependentSelectTarget.value) {
      return null
    }

    const selectedOption = this.dependentSelectTarget.options[this.dependentSelectTarget.selectedIndex]
    return selectedOption ? selectedOption.text : null
  }

  setSelection(isForSelf, dependentId = null) {
    if (isForSelf) {
      this.initializeSelfApplication()
    } else {
      this.initializeDependentApplication(dependentId)
    }
  }
}
