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
  
  togglePassword(event) {
    
    event.preventDefault();
    
    const button = event.currentTarget;
    
    const container = button.closest(".relative");
    
    let passwordField;
    
    if (this.hasFieldTarget && container.contains(this.fieldTarget)) {
      passwordField = this.fieldTarget;
    } else if (this.hasFieldConfirmationTarget && container.contains(this.fieldConfirmationTarget)) {
      passwordField = this.fieldConfirmationTarget;
    } else {
      
      const inputs = Array.from(container.querySelectorAll("input"));
      
      passwordField = inputs.find(input => {
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

    const isVisible = passwordField.type === "text";
    const newVisibility = !isVisible;

    passwordField.type = newVisibility ? "text" : "password";
    
    button.setAttribute("aria-pressed", newVisibility);
    button.setAttribute("aria-label", newVisibility ? this.hideLabelValue : this.showLabelValue);
    
    button.classList.toggle("eye-open", newVisibility);
    button.classList.toggle("eye-closed", !newVisibility);
    
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
        
        if (statusElement) {
          statusElement.textContent = this.hiddenStatusValue;
        }
      }, this.timeoutValue);
    } else {
      clearTimeout(this.visibilityTimeout);
    }
  }
  
  disconnect() {
    clearTimeout(this.visibilityTimeout);
  }
}
