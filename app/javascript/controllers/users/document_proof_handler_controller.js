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
    "noneRadio",
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
   * Handle "None Provided" radio button selection
   * UX shortcut that automatically selects reject + none_provided reason
   * @param {Event} event The change event from the none radio button
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
   * Preview the rejection reason text
   */
  previewRejectionReason() {
    if (this.hasReasonPreviewTarget && this.hasRejectionReasonSelectTarget) {
      const selectTarget = this.rejectionReasonSelectTarget;
      const previewTarget = this.reasonPreviewTarget;
      const selectedReason = selectTarget.value;

      if (selectedReason) {
        // In a real app, we'd use I18n or data attributes to get formatted reason text
        previewTarget.textContent = this.formatRejectionReason(selectedReason);
        setVisible(previewTarget, true);
      } else {
        setVisible(previewTarget, false);
      }
    }
  }
  
  /**
   * Format a rejection reason code into human-readable text
   * @param {string} reasonCode The rejection reason code
   * @returns {string} Formatted reason text
   */
  formatRejectionReason(reasonCode) {
    // This would typically come from Rails I18n
    const reasonMessages = {
      'none_provided': this.getNoneProvidedMessage(),
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
   * Get the appropriate "none provided" message based on proof type
   * @returns {string} The none provided message
   */
  getNoneProvidedMessage() {
    if (this.typeValue === 'income') {
      return 'No income proof was provided with the application.';
    } else {
      return 'No residency proof was provided with the application.';
    }
  }

  /**
   * Populate the rejection notes field with appropriate text based on selected reason
   */
  populateRejectionNotes() {
    if (this.hasRejectionNotesTarget && this.hasRejectionReasonSelectTarget) {
      const notesTarget = this.rejectionNotesTarget;
      const selectTarget = this.rejectionReasonSelectTarget;
      const selectedReason = selectTarget.value;
      
      if (selectedReason && !notesTarget.value) {
        // Only populate if the field is empty
        const reasonText = this.formatRejectionReason(selectedReason);
        const instructionalText = this.getInstructionalText(selectedReason);
        notesTarget.value = `${reasonText} ${instructionalText}`;
      }
    }
  }

  /**
   * Get instructional text for rejection reasons
   * @param {string} reasonCode The rejection reason code
   * @returns {string} Instructional text
   */
  getInstructionalText(reasonCode) {
    const instructions = {
      'none_provided': this.getNoneProvidedInstructions(),
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

  /**
   * Get the appropriate instructions for "none provided" based on proof type
   * @returns {string} The instructional text
   */
  getNoneProvidedInstructions() {
    if (this.typeValue === 'income') {
      return `Please provide ONE of the following to complete your application:

• If you receive Social Security (SSA), SSI, or SSDI: Send your most recent Social Security Award Letter.

• If you receive Veterans (VA) benefits, TDAP, TANF, or pharmacy/medical/housing assistance: Send your most recent benefit paperwork.

• If you live on a limited or fixed income: Send your 2 most recent pay stubs, unemployment stubs, or last year's tax return.`;
    } else {
      return 'Please provide proof of Maryland residency to complete your application. Acceptable documents include: utility bill, mortgage statement, lease agreement, bank statement, or government ID. IMPORTANT: The address shown on your proof document must match the address you provided in your application.';
    }
  }
}

export default DocumentProofHandlerController
