import { Controller } from "@hotwired/stimulus";
import { setVisible, setFieldValue } from "../../utils/visibility";

// Admin paper intake: guardian selection, the dependents frame, and last-application reuse.
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

  // selectGuardian and clearSelection are called by admin user search through its outlet.
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

    if (this.hasDependentIdFieldTarget) {
      this.dependentIdFieldTarget.value = dependentId;
    }

    if (this.hasApplicantTypeRadioDependentTarget) {
      this.applicantTypeRadioDependentTarget.checked = true;
    }

    this.loadDependentForm(dependentId);

    this.dispatchSelectionChange();
  }

  loadDependentForm(dependentId) {
    const frame = document.getElementById('dependent_info_form');
    if (!frame) return;

    const url = `/admin/paper_applications/dependent_form${dependentId ? `?dependent_id=${dependentId}` : ''}`;
    frame.src = url;
  }

  /**
   * Moves focus to the on-file dependent list, not to the blank First Name field.
   *
   * "Change Dependent" usually means "pick the right person". The dismissed card warns staff not to
   * create a duplicate to work around a bad record, and an empty name field would push them toward
   * that. The new-dependent form stays one Tab away.
   *
   * If the list has not rendered its chooser yet, the frame takes focus. The frame has a label and
   * tabindex="-1", so focus goes to an announced element, not to <body>.
   * @private
   */
  _focusDependentChooser() {
    if (!this.hasDependentsFrameTarget) return

    const chooser = this.dependentsFrameTarget.querySelector('button:not([disabled]), a[href]')
    if (chooser) {
      chooser.focus()
      return
    }

    this.dependentsFrameTarget.focus()
  }

  /**
   * Staff intent: "this is the wrong dependent, let me pick another." The dependent card's button
   * calls it through the applicant-type outlet. `clearDependentSelection` stays the internal
   * operation, so callers are not told apart by whether their argument is an Event.
   *
   * Turbo replaces the frame that holds the button. Without an explicit focus move, focus falls
   * to <body>, and a keyboard user is left at the top of a very long form.
   */
  changeDependent() {
    // Move focus first, synchronously. The chooser is outside the frame that reloads, so there is
    // nothing to wait for. Focus then never rests on the button that Turbo destroys, so a slow or
    // failed response cannot leave a keyboard user on <body>.
    this._focusDependentChooser()
    this.clearDependentSelection()
  }

  clearDependentSelection({ dispatch = true } = {}) {
    if (this.hasDependentIdFieldTarget) {
      this.dependentIdFieldTarget.value = "";
    }

    this.loadDependentForm(null);

    if (this.hasDisplaySelectionTarget) {
      this.displaySelectionTarget.innerHTML = '';
    }

    if (dispatch) {
      this.dispatchSelectionChange();
    }
  }

  dispatchSelectionChange() {
    this.dispatch("selectionChange", { detail: { selectedValue: this.selectedValue } });
  }
}
