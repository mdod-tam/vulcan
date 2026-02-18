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
    "reasonPreview"
  ]

  static values = {
    type: String // "income" or "residency"
  }

  connect() {
    // Set initial state based on selected radio button
    this.updateVisibility();
    
    // Add event listener for rejection reason selection
    if (this.hasRejectionReasonSelectTarget) {
      this.rejectionReasonSelectTarget.addEventListener('change', () => {
        this.previewRejectionReason();
        this.populateRejectionNotes();
      });
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

    // Update visibility and populate notes
    this.updateVisibility();
    this.previewRejectionReason();
    this.populateRejectionNotes();
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
      const target = this.rejectionNotesTarget;
      if (isAccepted) {
        target.removeAttribute('required');
      }
      // If rejectionNotes should be required when rejecting, add:
      // else { target.setAttribute('required', 'required'); }
    }
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

  /**
   * Populate the rejection notes field with the selected reason's body text.
   * Only populates when the field is empty to avoid overwriting admin edits.
   */
  populateRejectionNotes() {
    if (!this.hasRejectionNotesTarget || !this.hasRejectionReasonSelectTarget) return

    const notesTarget = this.rejectionNotesTarget
    if (notesTarget.value) return

    const selectTarget = this.rejectionReasonSelectTarget
    const selectedOption = selectTarget.options[selectTarget.selectedIndex]
    const reasonText = selectedOption?.dataset.reasonText

    if (reasonText) {
      notesTarget.value = reasonText
    }
  }
}

export default DocumentProofHandlerController
