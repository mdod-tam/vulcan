import { Controller } from "@hotwired/stimulus";
import { setVisible, setFieldValue } from "../../utils/visibility";
import { debouncedDispatch } from "../../utils/debounce";

// Handles guardian‑selection UI toggling and central state.
export default class extends Controller {
  static targets = [
    "searchPane",
    "selectedPane",
    "guardianIdField",
    "dependentsFrame",
    "dependentIdField",
    "applicantTypeRadioDependent",
    "displaySelection",
    "lastApplicationSummary",
    "lastApplicationSource",
    "lastApplicationDetails",
    "incomeCopyButton",
    "medicalCopyButton"
  ];

  connect() {
    this.selectedValue = !!(this.hasGuardianIdFieldTarget && this.guardianIdFieldTarget.value);
    this._lastApplicationContext = null;
    this.togglePanes();

    if (this.selectedValue && this.guardianIdFieldTarget.value) {
      this.loadDependentsFrame(this.guardianIdFieldTarget.value);
      this.loadLastApplicationContext(this.guardianIdFieldTarget.value);
    }
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
    this.loadLastApplicationContext(id);
  }

  clearSelection() {
    if (this.hasGuardianIdFieldTarget) this.guardianIdFieldTarget.value = "";
    this.selectedValue = false;
    this.clearDependentSelection({ dispatch: false });
    this.togglePanes();
    this.dispatchSelectionChange();
    this.clearDependentsFrame();
    this._lastApplicationContext = null;
    this.hideLastApplicationSummary();
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

  async loadLastApplicationContext(guardianId) {
    try {
      const response = await fetch(`/admin/users/${guardianId}/last_application_values`, {
        headers: { 'Accept': 'application/json' },
        credentials: 'same-origin'
      })
      if (!response.ok) return;
      const data = await response.json();
      if (!data.success || !data.application_id) return this.hideLastApplicationSummary();

      this._lastApplicationContext = data;
      this.showLastApplicationSummary(data);
    } catch (e) {
      console.warn('loadLastApplicationContext failed', e);
    }
  }

  showLastApplicationSummary(data) {
    if (!this.hasLastApplicationSummaryTarget) return;

    const parts = [];
    if (data.household_size) parts.push(`Household size: ${data.household_size}`);
    if (data.annual_income) parts.push(`Annual income: $${Number(data.annual_income).toLocaleString()}`);
    if (data.medical_provider_name) parts.push(`Medical provider: ${data.medical_provider_name}`);

    let dateStr = '';
    if (data.application_date) {
      const date = new Date(data.application_date)
      dateStr = ` (${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })})`
    }
    const sourceText = data.applicant_name
      ? `${data.applicant_name}'s application${dateStr}`
      : `previous application${dateStr}`;

    if (this.hasLastApplicationSourceTarget) this.lastApplicationSourceTarget.textContent = sourceText;
    if (this.hasLastApplicationDetailsTarget) this.lastApplicationDetailsTarget.textContent = parts.join(' • ');
    if (this.hasIncomeCopyButtonTarget) {
      setVisible(this.incomeCopyButtonTarget, !!(data.household_size || data.annual_income));
    }
    if (this.hasMedicalCopyButtonTarget) {
      setVisible(this.medicalCopyButtonTarget, !!(
        data.medical_provider_name ||
        data.medical_provider_phone ||
        data.medical_provider_fax ||
        data.medical_provider_email
      ));
    }

    setVisible(this.lastApplicationSummaryTarget, true);
  }

  hideLastApplicationSummary() {
    this._lastApplicationContext = null;
    if (this.hasLastApplicationSummaryTarget) setVisible(this.lastApplicationSummaryTarget, false);
  }

  useLastApplicationIncomeInfo() {
    const data = this._lastApplicationContext;
    if (!data) return;

    setFieldValue('input[name="application[household_size]"]', data.household_size);
    setFieldValue('input[name="application[annual_income]"]', data.annual_income);
  }

  useLastApplicationMedicalProvider() {
    const data = this._lastApplicationContext;
    if (!data) return;

    setFieldValue('input[name="application[medical_provider_name]"]', data.medical_provider_name);
    setFieldValue('input[name="application[medical_provider_phone]"]', data.medical_provider_phone);
    setFieldValue('input[name="application[medical_provider_fax]"]', data.medical_provider_fax);
    setFieldValue('input[name="application[medical_provider_email]"]', data.medical_provider_email);
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
  clearDependentSelection({ dispatch = true } = {}) {
    if (this.hasDependentIdFieldTarget) {
      this.dependentIdFieldTarget.value = "";
    }

    // Load blank form via Turbo Frame
    this.loadDependentForm(null);

    if (this.hasDisplaySelectionTarget) {
      this.displaySelectionTarget.innerHTML = '';
    }

    if (dispatch) {
      this.dispatchSelectionChange();
    }
  }

  dispatchSelectionChange() {
    debouncedDispatch(this, "selectionChange", { selectedValue: this.selectedValue });
  }
}
