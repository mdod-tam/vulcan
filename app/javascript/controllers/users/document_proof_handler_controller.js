import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

/**
 * Controls acceptance, later review, or rejection of one document.
 * The document-upload control owns the pending file.
 * This controller clears that file on rejection.
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
    this.restoreStateFromFormData();
    
    this.updateVisibility();
    
    if (this.hasRejectRadioTarget && this.rejectRadioTarget.checked) {
      this.previewRejectionReason();
      this.updateReasonInputMode();
    }
  }

  /**
   * Shows the sections for the review action restored by the server.
   */
  restoreStateFromFormData() {
    if (!this.hasAcceptRadioTarget || !this.hasRejectRadioTarget) {
      return;
    }

    const isAccepted = this.acceptRadioTarget.checked;
    const isUploadOnly = this.hasUploadOnlyRadioTarget && this.uploadOnlyRadioTarget.checked;
    const isRejected = this.rejectRadioTarget.checked;

    if (isAccepted || isUploadOnly || isRejected) {
      this.updateVisibility();
    }
  }

  /**
   * Updates sections for the selected review action.
   * @param {Event} event The change event from radio buttons
   */
  toggleProofAction(event) {
    this.updateVisibility();
  }

  /**
   * Selects rejection with the none_provided reason.
   * @param {Event} event The click event from the none button
   */
  handleNoneProvided(event) {
    if (!this.hasRejectRadioTarget || !this.hasRejectionReasonSelectTarget) {
      return;
    }

    this.rejectRadioTarget.checked = true;

    this.rejectionReasonSelectTarget.value = 'none_provided';

    this.updateVisibility();
    this.previewRejectionReason();
    this.updateReasonInputMode();
    this.rejectRadioTarget.dispatchEvent(new Event('change', { bubbles: true }));
  }

  /**
   * Shows file controls for acceptance or later review, and reason controls for rejection.
   */
  updateVisibility() {
    if (!this.hasAcceptRadioTarget || !this.hasUploadSectionTarget || !this.hasRejectionSectionTarget) {
      return;
    }

    const isAccepted = this.acceptRadioTarget.checked;
    const isUploadOnly = this.hasUploadOnlyRadioTarget && this.uploadOnlyRadioTarget.checked;
    const isRejected = this.rejectRadioTarget.checked;
  
    setVisible(this.uploadSectionTarget, isAccepted || isUploadOnly);
    setVisible(this.rejectionSectionTarget, isRejected);
    
    // The server reports missing files. Native required validation would prevent that response.
    if (this.hasFileInputTarget) {
      const target = this.fileInputTarget;
      target.disabled = !(isAccepted || isUploadOnly);

      // Rejection must submit no file, including a pending upload reference.
      if (isRejected) {
        this.uploadSectionTarget.querySelector('[data-controller~="document-upload"]')
          ?.dispatchEvent(new CustomEvent('document-upload:clear'));
      }
    }

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
   * data-reason-text supplies a database reason body or a literal fallback.
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
