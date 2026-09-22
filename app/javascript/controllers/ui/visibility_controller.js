// app/javascript/controllers/visibility_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "fieldConfirmation", "icon", "status"]

  static values = {
    timeout: { type: Number, default: 5000 }, // 5 seconds timeout
    hiddenStatus: { type: String, default: "Password is hidden" },
    visibleStatus: { type: String, default: "Password is visible" },
    showLabel: { type: String, default: "Show password" },
    hideLabel: { type: String, default: "Hide password" }
  }
  
  initialize() {
    this.visibilityTimeout = null;
    
    // Ensure we always have a valid timeout value
    // Priority: Stimulus value > default fallback
    if (!this.hasTimeoutValue) {
      this.timeoutValue = 5000; // Fallback default
    }
    
  }
  
  // This is the method called from the HTML
  togglePassword(event) {
    
    // Prevent the button from submitting the form
    event.preventDefault();
    
    // Get the button
    const button = event.currentTarget;
    
    // Get the container (parent with class "relative")
    const container = button.closest(".relative");
    
    // Find the password field
    let passwordField;
    
    // First try to find the field using Stimulus targets
    if (this.hasFieldTarget && container.contains(this.fieldTarget)) {
      passwordField = this.fieldTarget;
    } else if (this.hasFieldConfirmationTarget && container.contains(this.fieldConfirmationTarget)) {
      passwordField = this.fieldConfirmationTarget;
    } else {
      // Fallback to direct DOM query within the container
      
      // Find the input that's a direct child of the container
      const inputs = Array.from(container.querySelectorAll("input"));
      
      // Find the input that's a direct child or closest to the button
      passwordField = inputs.find(input => {
        // Check if it's a password field
        return input.type === 'password' || input.type === 'text';
      });
      
      if (!passwordField && inputs.length > 0) {
        passwordField = inputs[0];
      }
    }
    
    if (!passwordField) {
      console.error("Password visibility toggle has no input field.")
      return;
    }

    // Determine current and new visibility state
    const isVisible = passwordField.type === "text";
    const newVisibility = !isVisible;

    // Toggle the type
    passwordField.type = newVisibility ? "text" : "password";
    
    // Update accessibility attributes
    button.setAttribute("aria-pressed", newVisibility);
    button.setAttribute("aria-label", newVisibility ? this.hideLabelValue : this.showLabelValue);
    
    // Toggle icon class
    button.classList.toggle("eye-open", newVisibility);
    button.classList.toggle("eye-closed", !newVisibility);
    
    // Update status for screen readers
    const statusElement = this.hasStatusTarget ? this.statusTarget : 
                          document.getElementById(passwordField.getAttribute("aria-describedby"));
    
    if (statusElement) {
      statusElement.textContent = newVisibility ? this.visibleStatusValue : this.hiddenStatusValue;
    }
    
    // Security: Auto-hide after timeout (ensure timeoutValue is valid)
    if (newVisibility && this.timeoutValue > 0) {
      clearTimeout(this.visibilityTimeout);
      this.visibilityTimeout = setTimeout(() => {
        passwordField.type = "password";
        button.setAttribute("aria-pressed", "false");
        button.setAttribute("aria-label", this.showLabelValue);
        button.classList.remove("eye-open");
        button.classList.add("eye-closed");
        
        // Update status for screen readers
        if (statusElement) {
          statusElement.textContent = this.hiddenStatusValue;
        }
      }, this.timeoutValue);
    } else {
      clearTimeout(this.visibilityTimeout);
    }
  }
  
  disconnect() {
    // Clean up timeout when controller is disconnected
    clearTimeout(this.visibilityTimeout);
  }
}
