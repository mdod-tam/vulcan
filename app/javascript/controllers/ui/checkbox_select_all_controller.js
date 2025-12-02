import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="checkbox-select-all"
class CheckboxSelectAllController extends Controller {
  static targets = ["select", "checkbox", "actionButton", "downloadForm", "markPrintedForm"]

  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("CheckboxSelectAll controller connected")
    }
    this.updateButtonState()
    this.updateFormFields()
  }

  selectAll() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Select All clicked")
    }
    
    if (!this.hasSelectTarget || !this.hasCheckboxTargets) {
      return;
    }

    const isChecked = this.selectTarget.checked
    
    this.checkboxTargets.forEach(checkbox => {
      checkbox.checked = isChecked
    })
    
    this.updateButtonState()
    this.updateFormFields()
  }
  
  checkboxChanged() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Checkbox changed")
    }
    
    if (!this.hasSelectTarget || !this.hasCheckboxTargets) {
      return;
    }

    // Update the "select all" checkbox state based on individual checkboxes
    const allChecked = this.checkboxTargets.every(checkbox => checkbox.checked)
    const anyChecked = this.checkboxTargets.some(checkbox => checkbox.checked)
    
    this.selectTarget.checked = allChecked
    this.updateButtonState(anyChecked)
    this.updateFormFields()
  }
  
  updateButtonState(anyChecked = null) {
    if (anyChecked === null && this.hasCheckboxTargets) {
      anyChecked = this.checkboxTargets.some(checkbox => checkbox.checked)
    }
    
    // Update all submit buttons using target safety
    this.actionButtonTargets.forEach(button => {
      button.disabled = !anyChecked
    })
  }
  
  // Update the form fields for both forms
  updateFormFields() {
    // Update the download form
    if (this.hasDownloadFormTarget) {
      this.updateFormWithIds(this.downloadFormTarget);
    }
    
    // Update the mark as printed form
    if (this.hasMarkPrintedFormTarget) {
      this.updateFormWithIds(this.markPrintedFormTarget);
    }
  }
  
  // Helper method to update a form with letter_ids
  updateFormWithIds(form) {
    // Clear any existing hidden fields from the form
    const existingFields = form.querySelectorAll('input[name="letter_ids[]"]');
    existingFields.forEach(field => field.remove());
    
    // Get all checked checkboxes using target safety
    if (!this.hasCheckboxTargets) return;
    
    const checkedBoxes = this.checkboxTargets.filter(checkbox => checkbox.checked);
    
    // Add hidden field for each selected checkbox to the form
    checkedBoxes.forEach(checkbox => {
      const hiddenInput = document.createElement('input');
      hiddenInput.type = 'hidden';
      hiddenInput.name = 'letter_ids[]';
      hiddenInput.value = checkbox.value;
      form.appendChild(hiddenInput);
    });
  }
}

// Apply target safety mixin

export default CheckboxSelectAllController
