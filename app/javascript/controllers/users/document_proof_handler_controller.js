import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

/**
 * Controller for handling document proof acceptance/rejection
 * 
 * Manages the UI for accepting or rejecting proof documents,
 * toggling file upload sections, and handling rejection reasons.
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
    "customReasonField",
    "savedUpload",
    "removeUpload",
    "cancelUpload"
  ]

  static values = {
    type: String // "income" or "residency"
  }

  connect() {
    this.uploadForm = this.element.closest('form');
    this._releaseUploads = this.releaseUploadControls.bind(this);
    this.uploadForm?.addEventListener('direct-uploads:end', this._releaseUploads);
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
    this.uploadForm?.removeEventListener('direct-uploads:end', this._releaseUploads);
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

  signedInputs() {
    if (!this.hasFileInputTarget) return [];
    return Array.from(this.element.querySelectorAll('input[type="hidden"]'))
      .filter(input => input.name === this.fileInputTarget.name);
  }

  removeUpload() {
    if (this.uploading) return;
    this.signedInputs().forEach(input => input.remove());
    this.fileInputTarget.value = '';
    if (this.hasSavedUploadTarget) this.savedUploadTarget.textContent = '';
    this.fileInputTarget.dispatchEvent(new Event('change', { bubbles: true }));
  }

  uploadStarted() {
    this.previousUploadText = this.hasSavedUploadTarget ? this.savedUploadTarget.textContent : '';
    this.uploading = true;
    this.uploadError = false;
    this.uploadCanceled = false;
    this.uploadLockedControls = Array.from(this.element.querySelectorAll('input[type="radio"], button'))
      .filter(control => !control.disabled);
    this.uploadLockedControls.forEach(control => { control.disabled = true; });
    if (this.hasRemoveUploadTarget) this.removeUploadTarget.disabled = true;
    if (this.hasSavedUploadTarget) this.savedUploadTarget.textContent = 'Uploading document…';
    if (this.hasCancelUploadTarget) {
      this.cancelUploadTarget.disabled = false;
      this.cancelUploadTarget.hidden = false;
    }
  }

  rememberUploadRequest(event) {
    this.uploadXHR = event.detail.xhr;
    // Active Storage handles network errors, but does not subscribe to XHR aborts.
    this.uploadXHR.addEventListener('abort', () => event.detail.xhr.dispatchEvent(new Event('error')), { once: true });
    if (this.uploadCanceled) queueMicrotask(() => event.detail.xhr.abort());
  }

  cancelUpload() {
    this.uploadCanceled = true;
    this.uploadXHR?.abort();
  }

  uploadFailed(event) {
    event.preventDefault();
    this.uploadError = true;
    if (this.hasSavedUploadTarget) {
      this.savedUploadTarget.textContent = this.uploadCanceled
        ? 'Upload canceled. Any previous upload is retained.'
        : 'Upload failed. Retry or choose another file. Any previous upload is retained.';
    }
  }

  uploadFinished() {
    this.releaseUploadControls();
    if (this.uploadError) return;

    // Active Storage inserts the completed reference immediately before its file input.
    const completed = this.fileInputTarget.previousElementSibling;
    if (completed?.type !== 'hidden' || !completed.value) return;
    this.signedInputs().filter(input => input !== completed).forEach(input => input.remove());
    if (this.hasSavedUploadTarget) {
      this.savedUploadTarget.textContent = `Uploaded: ${this.fileInputTarget.files[0]?.name || 'document'}`;
    }
  }

  releaseUploadControls() {
    if (!this.uploading) return;
    if (!this.uploadError && this.hasSavedUploadTarget) this.savedUploadTarget.textContent = this.previousUploadText;
    this.uploading = false;
    this.uploadXHR = null;
    if (this.hasCancelUploadTarget) this.cancelUploadTarget.hidden = true;
    this.uploadLockedControls?.forEach(control => { control.disabled = false; });
    if (this.hasRemoveUploadTarget) this.removeUploadTarget.disabled = false;
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

      if (isRejected) {
        // Clear file when switching to reject
        if (target.value) {
          target.value = '';
        }
        this.signedInputs().forEach(input => input.remove());
        if (this.hasSavedUploadTarget) this.savedUploadTarget.textContent = '';
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
