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
    "rejectRadio",
    "noneButton",
    "uploadSection",
    "rejectionSection",
    "fileInput",
    "rejectionReasonSelect",
    "rejectionNotes",
    "reasonPreview",
    "customNotesSection"
  ]

  static values = {
    type: String // "income" or "residency"
  }

  connect() {
    // Restore state from form data if rejection fields have values
    this.restoreStateFromFormData();
    
    // Set initial state based on selected radio button
    this.updateVisibility();
    
    // Initialize rejection UI state if rejection is selected
    if (this.hasRejectRadioTarget && this.rejectRadioTarget.checked) {
      this.previewRejectionReason();
      this.updateReasonInputMode();
    }
    
    // Add event listener for rejection reason selection
    if (this.hasRejectionReasonSelectTarget) {
      this._boundReasonSelectionChanged = this.handleReasonSelectionChanged.bind(this);
      this.rejectionReasonSelectTarget.addEventListener('change', this._boundReasonSelectionChanged);
    }
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
    const isRejected = this.rejectRadioTarget.checked;

    if (isAccepted || isRejected) {
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
    const isRejected = this.rejectRadioTarget.checked;
  
    // Toggle visibility of sections using utility
    // Note: display:none automatically removes elements from accessibility tree
    setVisible(this.uploadSectionTarget, isAccepted);
    setVisible(this.rejectionSectionTarget, isRejected);
    
    // Toggle file input enabled state
    // Note: We don't set 'required' attribute to allow server-side validation to handle missing files
    if (this.hasFileInputTarget) {
      const target = this.fileInputTarget;
      target.disabled = !isAccepted;

      if (!isAccepted) {
        // Clear file when switching to reject
        if (target.value) {
          target.value = '';
        }
      }
    }

    // Toggle required attributes on fields
    if (this.hasRejectionReasonSelectTarget) {
      const target = this.rejectionReasonSelectTarget;
      if (isAccepted) {
        target.removeAttribute('required');
      } else {
        target.setAttribute('required', 'required');
      }
    }

    if (this.hasRejectionNotesTarget) {
      this.rejectionNotesTarget.removeAttribute('required');
    }

    if (isRejected) {
      this.previewRejectionReason();
      this.updateReasonInputMode();
    } else {
      this.hideCustomNotesInput();
    }
  }

  disconnect() {
    if (this.hasRejectionReasonSelectTarget && this._boundReasonSelectionChanged) {
      this.rejectionReasonSelectTarget.removeEventListener('change', this._boundReasonSelectionChanged);
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
    if (!this.hasRejectionReasonSelectTarget || !this.hasRejectionNotesTarget) return

    const selectedReason = this.rejectionReasonSelectTarget.value
    if (selectedReason === 'other') {
      if (this.hasCustomNotesSectionTarget) {
        setVisible(this.customNotesSectionTarget, true)
      }
      this.rejectionNotesTarget.disabled = false
      this.rejectionNotesTarget.setAttribute('required', 'required')
      return
    }

    this.hideCustomNotesInput()
  }

  hideCustomNotesInput() {
    if (this.hasCustomNotesSectionTarget) {
      setVisible(this.customNotesSectionTarget, false)
    }
    if (!this.hasRejectionNotesTarget) return

    this.rejectionNotesTarget.removeAttribute('required')
    this.rejectionNotesTarget.disabled = true
    if (this.rejectionNotesTarget.value) {
      this.rejectionNotesTarget.value = ''
    }
  }
}

export default DocumentProofHandlerController
