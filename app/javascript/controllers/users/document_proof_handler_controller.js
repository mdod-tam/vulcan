import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

const DECISION_CONTROLS = 'input[type="radio"], [data-document-proof-handler-target="noneButton"]'

/**
 * Controller for handling document proof acceptance/rejection
 *
 * Manages the decision for one document: accept, upload for later review, or reject with a reason.
 * The file itself is handled by the shared document-upload control inside uploadSection; this
 * controller clears it when rejection is chosen and locks its decision controls while it uploads.
 */
class DocumentProofHandlerController extends Controller {
  static targets = [
    "acceptRadio",
    "uploadOnlyRadio",
    "rejectRadio",
    "noneButton",
    "uploadSection",
    "rejectionSection",
    "fileInput",
    "rejectionReasonSelect",
    "reasonPreview",
    "languageNotice",
    "customReasonSection",
    "customReasonField"
  ]

  connect() {
    this.uploadForm = this.element.closest('form');
    this._lockDecisions = this.lockDecisionControls.bind(this);
    this._unlockDecisions = this.unlockDecisionControls.bind(this);
    this._blockLockedDecision = this.blockLockedDecision.bind(this);
    this.element.addEventListener('direct-upload:initialize', this._lockDecisions);
    this.element.addEventListener('click', this._blockLockedDecision, true);
    this.uploadForm?.addEventListener('direct-uploads:end', this._unlockDecisions);
    // Restore state from form data if rejection fields have values
    this.restoreStateFromFormData();
    
    // Set initial state based on selected radio button
    this.updateVisibility();
    
    // Initialize rejection UI state if rejection is selected
    if (this.hasRejectRadioTarget && this.rejectRadioTarget.checked) {
      this.previewRejectionReason();
      this.updateReasonInputMode();
    }
  }

  disconnect() {
    this.element.removeEventListener('direct-upload:initialize', this._lockDecisions);
    this.element.removeEventListener('click', this._blockLockedDecision, true);
    this.uploadForm?.removeEventListener('direct-uploads:end', this._unlockDecisions);
  }

  /**
   * Restore the UI state based on which radio button is checked
   * This handles cases where the form is re-rendered after validation errors
   */
  restoreStateFromFormData() {
    if (!this.hasAcceptRadioTarget || !this.hasRejectRadioTarget) {
      return;
    }

    // Check which radio button is currently selected and show the correct fields
    const isAccepted = this.acceptRadioTarget.checked;
    const isUploadOnly = this.hasUploadOnlyRadioTarget && this.uploadOnlyRadioTarget.checked;
    const isRejected = this.rejectRadioTarget.checked;

    if (isAccepted || isUploadOnly || isRejected) {
      // Radio button state is already set, just update visibility
      this.updateVisibility();
    }
  }

  /**
   * Toggle between accept/reject states
   * @param {Event} event The change event from radio buttons
   */
  toggleProofAction(event) {
    // Update UI based on selection
    this.updateVisibility();
  }

  // A decision cannot change while its document is uploading. The controls are not disabled:
  // Rails submits the form before it fires direct-uploads:end, and a disabled radio would be
  // left out of that submission.
  lockDecisionControls() {
    this.decisionsLocked = true;
    this.element.querySelectorAll(DECISION_CONTROLS)
      .forEach(control => control.setAttribute('aria-disabled', 'true'));
  }

  unlockDecisionControls() {
    if (!this.decisionsLocked) return;
    this.decisionsLocked = false;
    this.element.querySelectorAll(DECISION_CONTROLS)
      .forEach(control => control.removeAttribute('aria-disabled'));
  }

  // A canceled click leaves a radio unchanged, whether it came from the mouse, a label, or the keyboard
  blockLockedDecision(event) {
    if (!this.decisionsLocked || !event.target.closest(DECISION_CONTROLS)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }

  /**
   * Handle "None Provided" button click
   * UX shortcut that automatically selects reject + none_provided reason
   * @param {Event} event The click event from the none button
   */
  handleNoneProvided(event) {
    if (!this.hasRejectRadioTarget || !this.hasRejectionReasonSelectTarget) {
      return;
    }

    // Programmatically select the reject radio button
    this.rejectRadioTarget.checked = true;

    // Auto-select "none_provided" from rejection reason dropdown
    this.rejectionReasonSelectTarget.value = 'none_provided';

    // Update visibility and reason mode
    this.updateVisibility();
    this.previewRejectionReason();
    this.updateReasonInputMode();
    this.rejectRadioTarget.dispatchEvent(new Event('change', { bubbles: true }));
  }

  /**
   * Update the visibility of upload or rejection sections
   * based on the selected radio
   */
  updateVisibility() {
    if (!this.hasAcceptRadioTarget || !this.hasUploadSectionTarget || !this.hasRejectionSectionTarget) {
      return;
    }

    const isAccepted = this.acceptRadioTarget.checked;
    const isUploadOnly = this.hasUploadOnlyRadioTarget && this.uploadOnlyRadioTarget.checked;
    const isRejected = this.rejectRadioTarget.checked;
  
    // Toggle visibility of sections using utility
    // Note: display:none automatically removes elements from accessibility tree
    setVisible(this.uploadSectionTarget, isAccepted || isUploadOnly);
    setVisible(this.rejectionSectionTarget, isRejected);
    
    // Toggle file input enabled state
    // Note: We don't set 'required' attribute to allow server-side validation to handle missing files
    if (this.hasFileInputTarget) {
      const target = this.fileInputTarget;
      target.disabled = !(isAccepted || isUploadOnly);

      // A rejection carries no file, so any pending upload is cleared
      if (isRejected) {
        this.uploadSectionTarget.querySelector('[data-controller~="document-upload"]')
          ?.dispatchEvent(new CustomEvent('document-upload:clear'));
      }
    }

    // Toggle required attributes on fields
    if (this.hasRejectionReasonSelectTarget) {
      const target = this.rejectionReasonSelectTarget;
      if (isRejected) {
        target.setAttribute('required', 'required');
      } else {
        target.removeAttribute('required');
      }
    }

    if (isRejected) {
      this.previewRejectionReason();
      this.updateReasonInputMode();
    } else {
      this._hideCustomReasonAndNotice();
    }
  }


  handleReasonSelectionChanged() {
    this.previewRejectionReason();
    this.updateReasonInputMode();
  }

  /**
   * Preview the rejection reason text.
   * Reads the human-readable body from the selected option's data-reason-text attribute,
   * which is populated server-side from the RejectionReason DB records.
   */
  previewRejectionReason() {
    if (!this.hasReasonPreviewTarget || !this.hasRejectionReasonSelectTarget) return

    const selectTarget = this.rejectionReasonSelectTarget
    const previewTarget = this.reasonPreviewTarget
    const selectedOption = selectTarget.options[selectTarget.selectedIndex]
    const reasonText = selectedOption?.dataset.reasonText

    if (reasonText) {
      previewTarget.textContent = reasonText
      setVisible(previewTarget, true)
    } else {
      setVisible(previewTarget, false)
    }
  }

  updateReasonInputMode() {
    if (!this.hasRejectionReasonSelectTarget) return

    const isOther = this.rejectionReasonSelectTarget.value === 'other'

    if (this.hasLanguageNoticeTarget) {
      setVisible(this.languageNoticeTarget, isOther)
    }

    if (this.hasCustomReasonSectionTarget) {
      setVisible(this.customReasonSectionTarget, isOther)
    }
    if (this.hasCustomReasonFieldTarget) {
      this.customReasonFieldTarget.disabled = !isOther
      if (isOther) {
        this.customReasonFieldTarget.setAttribute('required', 'required')
      } else {
        this.customReasonFieldTarget.removeAttribute('required')
        this.customReasonFieldTarget.value = ''
      }
    }
  }

  _hideCustomReasonAndNotice() {
    if (this.hasLanguageNoticeTarget) {
      setVisible(this.languageNoticeTarget, false)
    }
    if (this.hasCustomReasonSectionTarget) {
      setVisible(this.customReasonSectionTarget, false)
    }
    if (this.hasCustomReasonFieldTarget) {
      this.customReasonFieldTarget.removeAttribute('required')
      this.customReasonFieldTarget.disabled = true
      this.customReasonFieldTarget.value = ''
    }
  }
}

export default DocumentProofHandlerController
