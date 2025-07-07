import { Controller } from "@hotwired/stimulus"
import { applyTargetSafety } from "../../mixins/target_safety"
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
    "uploadSection",
    "rejectionSection",
    "fileInput",
    "rejectionReasonSelect",
    "rejectionNotes",
    "reasonPreview"
  ]

  static values = {
    proofType: String // "income_proof" or "residency_proof"
  }

  connect() {
    // Set initial state based on selected radio button
    this.updateVisibility();
    
    // Add event listener for rejection reason selection
    this.withTarget('rejectionReasonSelect', (target) => {
      target.addEventListener('change', () => {
        this.previewRejectionReason();
        this.populateRejectionNotes();
      });
    });
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
   * Update the visibility of upload or rejection sections
   * based on the selected radio
   */
  updateVisibility() {
    if (!this.hasRequiredTargets('acceptRadio', 'uploadSection', 'rejectionSection')) {
      return;
    }

    const isAccepted = this.acceptRadioTarget.checked;
    
    // Toggle visibility of sections using utility
    setVisible(this.uploadSectionTarget, isAccepted);
    setVisible(this.rejectionSectionTarget, !isAccepted);
    
    // Toggle file input enabled state
    this.withTarget('fileInput', (target) => {
      target.disabled = !isAccepted;

      // Clear file when switching to reject
      if (!isAccepted && target.value) {
        target.value = '';
      }
    });

    // Toggle required attributes on fields
    this.withTarget('rejectionReasonSelect', (target) => {
      if (isAccepted) {
        target.removeAttribute('required');
      } else {
        target.setAttribute('required', 'required');
      }
    });

    this.withTarget('rejectionNotes', (target) => {
      if (isAccepted) {
        target.removeAttribute('required');
      }
      // If rejectionNotes should be required when rejecting, add:
      // else { target.setAttribute('required', 'required'); }
    });
  }

  /**
   * Preview the rejection reason text
   */
  previewRejectionReason() {
    this.withTarget('reasonPreview', (previewTarget) => {
      this.withTarget('rejectionReasonSelect', (selectTarget) => {
        const selectedReason = selectTarget.value;

        if (selectedReason) {
          // In a real app, we'd use I18n or data attributes to get formatted reason text
          previewTarget.textContent = this.formatRejectionReason(selectedReason);
          setVisible(previewTarget, true);
        } else {
          setVisible(previewTarget, false);
        }
      });
    });
  }
  
  /**
   * Format a rejection reason code into human-readable text
   * @param {string} reasonCode The rejection reason code
   * @returns {string} Formatted reason text
   */
  formatRejectionReason(reasonCode) {
    // This would typically come from Rails I18n
    const reasonMessages = {
      'address_mismatch': 'The address on the document does not match the application address.',
      'expired': 'The document has expired or is not within the required date range.',
      'missing_name': 'The document does not clearly show the applicant\'s name.',
      'wrong_document': 'This is not an acceptable document type for this proof.',
      'missing_amount': 'The income amount is not clearly visible on the document.',
      'exceeds_threshold': 'The income shown exceeds the program\'s threshold.',
      'outdated_ss_award': 'The Social Security award letter is from a previous year.',
      'other': 'There is an issue with this document. Please see notes for details.'
    };
    
    return reasonMessages[reasonCode] || 'This document was rejected. Please provide a valid document.';
  }

  /**
   * Populate the rejection notes field with appropriate text based on selected reason
   */
  populateRejectionNotes() {
    this.withTarget('rejectionNotes', (notesTarget) => {
      this.withTarget('rejectionReasonSelect', (selectTarget) => {
        const selectedReason = selectTarget.value;
        
        if (selectedReason && !notesTarget.value) {
          // Only populate if the field is empty
          const reasonText = this.formatRejectionReason(selectedReason);
          const instructionalText = this.getInstructionalText(selectedReason);
          notesTarget.value = `${reasonText} ${instructionalText}`;
        }
      });
    });
  }

  /**
   * Get instructional text for rejection reasons
   * @param {string} reasonCode The rejection reason code
   * @returns {string} Instructional text
   */
  getInstructionalText(reasonCode) {
    const instructions = {
      'address_mismatch': 'Please provide a document that shows your current address.',
      'expired': 'Please provide a current document that is not expired.',
      'missing_name': 'Please provide a document that clearly shows your name.',
      'wrong_document': 'Please provide an acceptable document type for this proof.',
      'missing_amount': 'Please provide a document that clearly shows the income amount.',
      'exceeds_threshold': 'Unfortunately, your income exceeds the program eligibility threshold.',
      'outdated_ss_award': 'Please provide your most recent Social Security award letter.',
      'other': 'Please contact us for more information about the required documentation.'
    };
    
    return instructions[reasonCode] || 'Please provide the required documentation.';
  }
}

// Apply target safety mixin
applyTargetSafety(DocumentProofHandlerController)

export default DocumentProofHandlerController
