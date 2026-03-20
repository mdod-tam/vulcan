import { Controller } from "@hotwired/stimulus";
import { setVisible, setFieldIfEmpty } from "../../utils/visibility";
import { debouncedDispatch } from "../../utils/debounce";

// Handles guardian‑selection UI toggling and central state.
export default class extends Controller {
  static targets = ["searchPane", "selectedPane", "guardianIdField", "dependentsFrame", "dependentIdField", "applicantTypeRadioDependent", "displaySelection"];

  connect() {
    this.selectedValue = !!(this.hasGuardianIdFieldTarget && this.guardianIdFieldTarget.value);
    this.togglePanes();
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
    this.hideMedicalProviderPrefillNotice();
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

      let foundAny = false
      foundAny = setFieldIfEmpty('input[name="application[household_size]"]', data.household_size) || foundAny
      foundAny = setFieldIfEmpty('input[name="application[annual_income]"]', data.annual_income) || foundAny
      
      let medicalPrefilled = false
      medicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_name]"]', data.medical_provider_name) || medicalPrefilled
      medicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_phone]"]', data.medical_provider_phone) || medicalPrefilled
      medicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_fax]"]', data.medical_provider_fax) || medicalPrefilled
      medicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_email]"]', data.medical_provider_email) || medicalPrefilled
      foundAny = foundAny || medicalPrefilled
      
      // Show prefill notice if medical provider data was reused
      if (medicalPrefilled) {
        this.showMedicalProviderPrefillNotice(data.applicant_name, data.application_date)
      }

      if (!foundAny) {
        // Retry after UI settles
        setTimeout(() => {
          let retryMedicalPrefilled = false
          setFieldIfEmpty('input[name="application[household_size]"]', data.household_size)
          setFieldIfEmpty('input[name="application[annual_income]"]', data.annual_income)
          retryMedicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_name]"]', data.medical_provider_name) || retryMedicalPrefilled
          retryMedicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_phone]"]', data.medical_provider_phone) || retryMedicalPrefilled
          retryMedicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_fax]"]', data.medical_provider_fax) || retryMedicalPrefilled
          retryMedicalPrefilled = setFieldIfEmpty('input[name="application[medical_provider_email]"]', data.medical_provider_email) || retryMedicalPrefilled
          
          if (retryMedicalPrefilled) {
            this.showMedicalProviderPrefillNotice(data.applicant_name, data.application_date)
          }
        }, 150)
      }
    } catch (e) {
      // Silent fail to avoid interrupting admin flow
      console.warn('prefillFromLastApplication failed', e);
    }
  }

  showMedicalProviderPrefillNotice(applicantName, applicationDate) {
    const notice = document.getElementById('medical-provider-prefill-notice')
    const source = document.getElementById('medical-provider-prefill-source')
    if (!notice || !source) return

    // Format date if available
    let dateStr = ''
    if (applicationDate) {
      const date = new Date(applicationDate)
      dateStr = ` (${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })})`
    }

    // Update source text with applicant info
    source.textContent = applicantName 
      ? `${applicantName}'s application${dateStr}`
      : `previous application${dateStr}`

    // Show the notice
    notice.classList.remove('hidden')
  }

  hideMedicalProviderPrefillNotice() {
    const notice = document.getElementById('medical-provider-prefill-notice')
    if (notice) {
      notice.classList.add('hidden')
    }
  }

  // Called from dependents list partial buttons
  selectDependentFromList(event) {
    const button = event.currentTarget;
    const dependentId = button.dataset.dependentId;
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
    debouncedDispatch(this, "selectionChange", { selectedValue: this.selectedValue });
  }
}
