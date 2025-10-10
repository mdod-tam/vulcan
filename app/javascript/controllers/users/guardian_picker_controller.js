import { Controller } from "@hotwired/stimulus";
import { setVisible } from "../../utils/visibility";

// Handles guardian‑selection UI toggling and central state.
export default class extends Controller {
  static targets = ["searchPane", "selectedPane", "guardianIdField", "dependentsFrame", "dependentIdField", "applicantTypeRadioDependent", "displaySelection"];

  connect() {
    this.selectedValue = !!(this.hasGuardianIdFieldTarget && this.guardianIdFieldTarget.value);
    this.togglePanes();
    this._lastDispatchTime = 0;
  }

  /* Public API ----------------------------------------------------------- */
  selectGuardian(id, displayHTML) {
    if (this.hasGuardianIdFieldTarget) this.guardianIdFieldTarget.value = id;
    const box = this.selectedPaneTarget.querySelector(".guardian-details-container");
    if (box) box.innerHTML = displayHTML;
    this.selectedValue = true;
    this.togglePanes();
    this.dispatchSelectionChange();
    this.loadDependentsFrame(id);
    this.prefillFromLastApplication(id);
  }

  clearSelection() {
    if (this.hasGuardianIdFieldTarget) this.guardianIdFieldTarget.value = "";
    this.clearDependentSelection();
    this.selectedValue = false;
    this.togglePanes();
    this.dispatchSelectionChange();
    this.clearDependentsFrame();
  }

  /* Internal helpers ----------------------------------------------------- */
  togglePanes() {
    const hideSearch = this.selectedValue;
    setVisible(this.searchPaneTarget, !hideSearch);
    setVisible(this.selectedPaneTarget, hideSearch);
  }

  loadDependentsFrame(guardianId) {
    if (!this.hasDependentsFrameTarget) return;
    const src = `/admin/users/${guardianId}/dependents`;
    this.dependentsFrameTarget.src = src;
  }

  clearDependentsFrame() {
    if (!this.hasDependentsFrameTarget) return;
    this.dependentsFrameTarget.removeAttribute('src');
    this.dependentsFrameTarget.innerHTML = "";
  }

  async prefillFromLastApplication(guardianId) {
    try {
      // Slight delay to allow DOM sections to toggle
      await new Promise(r => setTimeout(r, 50))
      const response = await fetch(`/admin/users/${guardianId}/last_application_values`, {
        headers: { 'Accept': 'application/json' },
        credentials: 'same-origin'
      })
      if (!response.ok) return;
      const data = await response.json();
      if (!data.success || !data.application_id) return;

      const setIfEmpty = (selector, value) => {
        const el = document.querySelector(selector)
        if (!el) return false
        if (el.value === '' || el.value == null) {
          el.value = value ?? ''
          // Fire input/change events so any validators update
          el.dispatchEvent(new Event('input', { bubbles: true }))
          el.dispatchEvent(new Event('change', { bubbles: true }))
        }
        return true
      }

      // Try immediately, retry once if elements not yet present
      let foundAny = false
      foundAny = setIfEmpty('input[name="application[household_size]"]', data.household_size) || foundAny
      foundAny = setIfEmpty('input[name="application[annual_income]"]', data.annual_income) || foundAny
      foundAny = setIfEmpty('input[name="application[medical_provider_name]"]', data.medical_provider_name) || foundAny
      foundAny = setIfEmpty('input[name="application[medical_provider_phone]"]', data.medical_provider_phone) || foundAny
      foundAny = setIfEmpty('input[name="application[medical_provider_fax]"]', data.medical_provider_fax) || foundAny
      foundAny = setIfEmpty('input[name="application[medical_provider_email]"]', data.medical_provider_email) || foundAny

      if (!foundAny) {
        // Retry after UI settles
        setTimeout(() => {
          setIfEmpty('input[name="application[household_size]"]', data.household_size)
          setIfEmpty('input[name="application[annual_income]"]', data.annual_income)
          setIfEmpty('input[name="application[medical_provider_name]"]', data.medical_provider_name)
          setIfEmpty('input[name="application[medical_provider_phone]"]', data.medical_provider_phone)
          setIfEmpty('input[name="application[medical_provider_fax]"]', data.medical_provider_fax)
          setIfEmpty('input[name="application[medical_provider_email]"]', data.medical_provider_email)
        }, 150)
      }
    } catch (e) {
      // Silent fail to avoid interrupting admin flow
      console.warn('prefillFromLastApplication failed', e);
    }
  }

  // Called from dependents list partial buttons
  selectDependentFromList(event) {
    const button = event.currentTarget;
    const dependentId = button.dataset.dependentId;
    const dependentName = button.dataset.dependentName;
    if (!dependentId) return;

    // Set hidden field
    if (this.hasDependentIdFieldTarget) {
      this.dependentIdFieldTarget.value = dependentId;
    }

    // Ensure dependent radio is checked
    if (this.hasApplicantTypeRadioDependentTarget) {
      this.applicantTypeRadioDependentTarget.checked = true;
    }

    // Load pre-filled form via Turbo Frame (Rails handles the rendering)
    this.loadDependentForm(dependentId);

    this.dispatchSelectionChange();
  }

  // Load dependent form via Turbo Frame
  loadDependentForm(dependentId) {
    const frame = document.getElementById('dependent_info_form');
    if (!frame) return;

    const url = `/admin/paper_applications/dependent_form${dependentId ? `?dependent_id=${dependentId}` : ''}`;
    frame.src = url;
  }

  // Clear dependent selection and reload blank form
  clearDependentSelection() {
    if (this.hasDependentIdFieldTarget) {
      this.dependentIdFieldTarget.value = "";
    }

    // Load blank form via Turbo Frame
    this.loadDependentForm(null);

    if (this.hasDisplaySelectionTarget) {
      this.displaySelectionTarget.innerHTML = '';
    }

    this.dispatchSelectionChange();
  }

  dispatchSelectionChange() {
    // Debounce the dispatch to prevent rapid-fire events
    const now = Date.now();
    if (now - this._lastDispatchTime < 100) {
      return; // Skip if called too recently
    }
    this._lastDispatchTime = now;
    
    // Use a small delay to ensure DOM changes are complete
    setTimeout(() => {
      this.dispatch("selectionChange", { detail: { selectedValue: this.selectedValue } });
    }, 10);
  }
}
