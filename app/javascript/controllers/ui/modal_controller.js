import { Controller } from "@hotwired/stimulus"
import { applyTargetSafety } from "../../mixins/target_safety"
import { setVisible } from "../../utils/visibility"

// Declare targets and values for better structure
class ModalController extends Controller {
  static targets = ["container", "overlay"]

  static values = {
    id: String,
    preserveScroll: { type: Boolean, default: false }
  }

  connect() {
    // Use target safety for initialization
    if (!this.hasRequiredTargets('container')) {
      return
    }

    if (process.env.NODE_ENV !== 'production') {
      console.log("Modal controller connected", {
        id: this.element.id,
        targets: this.targets
      })
    }

    // Ensure modal is hidden on connect
    this.close()

    // Store bound methods for cleanup
    this._handleKeydown = this.handleKeydown.bind(this)
    this._handleTurboSubmitEnd = this.handleTurboSubmitEnd.bind(this)
    this._handleTurboFormSubmit = this.handleTurboFormSubmit.bind(this)

    // Set up document-level event listeners
    this._setupDocumentListeners()
    
    // Safety timeout to restore scroll if needed
    this._setupScrollSafetyTimeout()

    // Mark modal controller as connected for test synchronization
    this.element.setAttribute('data-modal-controller-connected', 'true')
  }

  disconnect() {
    this._cleanupDocumentListeners()
    
    if (this._scrollSafetyTimeout) {
      clearTimeout(this._scrollSafetyTimeout)
    }
    this.cleanup()
  }

  _setupDocumentListeners() {
    document.addEventListener("keydown", this._handleKeydown)
    document.addEventListener("turbo:submit-end", this._handleTurboSubmitEnd)
    document.addEventListener("turbo-form-submit", this._handleTurboFormSubmit)
  }

  _cleanupDocumentListeners() {
    document.removeEventListener("keydown", this._handleKeydown)
    document.removeEventListener("turbo:submit-end", this._handleTurboSubmitEnd)
    document.removeEventListener("turbo-form-submit", this._handleTurboFormSubmit)
  }

  open(event) {
    // Determine which modal element to show
    const modalId = event?.currentTarget?.dataset?.modalId
    
    // ✅ ACCEPTABLE: Keep dynamic getElementById for modal opening
    // This is needed for dynamic modal targeting where modal ID comes from data attributes
    const modalElement = modalId
      ? document.getElementById(modalId)
      : this.containerTarget

    if (!modalElement) {
      console.error("ModalController: could not find modal element", modalId)
      console.error("Error: Could not open modal. Please contact support.")
      return
    }

    // Transfer proof type data from the triggering button to rejection modals
    const proofType = event?.currentTarget?.dataset?.proofType
    if (process.env.NODE_ENV !== 'production') {
      console.log('Modal: Opening modal', modalId, 'with proof type', proofType)
    }
    if (proofType && (modalId === 'proofRejectionModal' || modalId === 'medicalCertificationRejectionModal')) {
      this._setProofTypeInModal(modalElement, proofType)
    }

    this._showModal(modalElement)
  }

  _setProofTypeInModal(modalElement, proofType) {
    // Find the hidden proof type field in the rejection modal
    const proofTypeField = modalElement.querySelector('#rejection-proof-type')
    if (proofTypeField) {
      proofTypeField.value = proofType
      
      if (process.env.NODE_ENV !== 'production') {
        console.log('Modal: Set proof type to', proofType, 'in field', proofTypeField)
      }
      
      // Trigger change event for any listeners
      proofTypeField.dispatchEvent(new Event('change', { bubbles: true }))
      
      // Try to find and notify the rejection form controller
      // First check if the modal itself has the rejection-form controller
      const formElement = modalElement.hasAttribute('data-controller') && modalElement.getAttribute('data-controller').includes('rejection-form')
        ? modalElement
        : modalElement.querySelector('[data-controller*="rejection-form"]')
      if (formElement) {
        if (process.env.NODE_ENV !== 'production') {
          console.log('Modal: Found rejection form element, dispatching proof-type-changed event with proofType:', proofType)
        }
        // Dispatch a custom event that the rejection form controller can listen for
        formElement.dispatchEvent(new CustomEvent('proof-type-changed', { 
          detail: { proofType },
          bubbles: true 
        }))
        if (process.env.NODE_ENV !== 'production') {
          console.log('Modal: Event dispatched')
        }
      } else {
        if (process.env.NODE_ENV !== 'production') {
          console.log('Modal: No rejection form element found in modal')
        }
      }
    }
  }

  _showModal(element) {
    // Reset PDF loaded state so that PDFs can be reloaded
    // ✅ ACCEPTABLE: Scoped query within the modal element
    element.querySelectorAll('iframe[data-original-src]').forEach((iframe) => {
      iframe.removeAttribute("data-pdf-loaded")
    })
    // Show modal, lock scroll, load PDFs, focus first input
    setVisible(element, true)
    this._lockScroll()
    this._loadIframes(element)
    // ✅ ACCEPTABLE: Scoped query within the modal element
    const firstInput = element.querySelector("input, textarea")
    firstInput?.focus()
    
    // Signal that modal is fully ready for tests
    element.setAttribute('data-test-modal-ready', 'true')
  }

  _lockScroll() {
    document.body.classList.add("overflow-hidden")
  }

  _unlockScroll() {
    document.body.classList.remove("overflow-hidden")
  }

  _loadIframes(element) {
    // ✅ ACCEPTABLE: Scoped query within the modal element for dynamic PDF content
    const iframes = element.querySelectorAll('iframe[data-original-src]')
    
    if (process.env.NODE_ENV !== 'production') {
      console.log(`Loading ${iframes.length} iframes in modal:`, element.id)
    }
    
    iframes.forEach((iframe, index) => {
      const already = iframe.getAttribute("data-pdf-loaded") === "true"
      if (already) {
        return
      }

      const originalSrc = iframe.getAttribute("data-original-src")
      if (!originalSrc) {
        console.error(`Iframe ${index}: Empty data-original-src on iframe`)
        console.error("Error: PDF URL is missing. Please contact support.")
        return
      }

      try {
        // Force refresh by replacing iframe with a new one
        const parent = iframe.parentNode;
        if (!parent) {
          console.warn("Iframe parent not found - iframe may have been removed from DOM");
          return;
        }
        
        const newIframe = iframe.cloneNode(true);
        newIframe.src = originalSrc + '&t=' + new Date().getTime(); // Add timestamp to bust cache
        
        newIframe.setAttribute("data-pdf-loading", "true");

        newIframe.addEventListener("load", () => {
          newIframe.setAttribute("data-pdf-loaded", "true");
          newIframe.removeAttribute("data-pdf-loading");
        });
        
        newIframe.addEventListener("error", e => {
          console.error("Error loading iframe:", e);
          newIframe.removeAttribute("data-pdf-loading");
          const errorContainer = document.createElement("div");
          errorContainer.className = "p-4 bg-red-50 border border-red-100 rounded my-2";
          errorContainer.innerHTML = `
            <p class="text-red-800 font-medium">Error loading PDF</p>
            <p class="text-red-600 text-sm">
              There was a problem loading the PDF. Try opening it directly:
              <a href="${originalSrc}" target="_blank" class="underline">Open PDF</a>
            </p>
          `;
          
          // Guard against parent being removed
          if (newIframe.parentNode) {
            newIframe.parentNode.insertBefore(errorContainer, newIframe);
          }
          console.error("Error loading PDF. Please try again or open directly.")
        });
        
        // Replace after event listeners are attached
        parent.replaceChild(newIframe, iframe);
      } catch (err) {
        console.error("Exception in _loadIframes:", err);
        console.error("An unexpected error occurred while loading PDF. Please try again.")
      }
    })
  }

  close(event) {
    event?.preventDefault()

    const modalElement =
      event?.currentTarget?.closest('[data-modal-target="container"]') ||
      this.containerTarget

    if (modalElement) {
      setVisible(modalElement, false)
      // ✅ ACCEPTABLE: Scoped query within the modal element
      modalElement.querySelectorAll('iframe[data-original-src]').forEach((iframe) => {
        iframe.removeAttribute("data-pdf-loaded")
      })
      // Remove modal ready signal
      modalElement.removeAttribute('data-test-modal-ready')
    }

    // Only remove overflow-hidden if no other modals are visible
    // ✅ ACCEPTABLE: Scoped query within the controller's element
    const anyVisible = this.element.querySelectorAll(
      '[data-modal-target="container"]:not(.hidden)'
    ).length > 0

    if (!this.preserveScrollValue && !anyVisible) {
      this._unlockScroll()
    }
  }

  handleFormSubmission(event) {
    const form = event.target
    const opensNewWindow = form.dataset.opensNewWindow === "true"

    if (opensNewWindow) {
      this.preserveScrollValue = true
      document.addEventListener(
        "visibilitychange",
        () => { this.cleanup() },
        { once: true }
      )
    } else {
      this.preserveScrollValue = false
    }
  }

  cleanup() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Cleaning up modal scroll state")
    }
    this.preserveScrollValue = false
    this._unlockScroll()
    // ✅ ACCEPTABLE: Scoped query within the controller's element
    this.element
      .querySelectorAll('[data-modal-target="container"]')
      .forEach(modal => setVisible(modal, false))
    this._setupScrollSafetyTimeout()
  }

  _setupScrollSafetyTimeout() {
    clearTimeout(this._scrollSafetyTimeout)
    this._scrollSafetyTimeout = setTimeout(() => {
      if (document.body.classList.contains("overflow-hidden")) {
        if (process.env.NODE_ENV !== 'production') {
          console.warn("Safety timeout: restoring scroll")
        }
        this._unlockScroll()
      }
    }, 2000)
  }

  handleTurboFormSubmit(event) {
    if (process.env.NODE_ENV !== 'production') {
      console.log("Turbo form submit received")
    }
    this._formSubmissionInProgress = true
    // ✅ ACCEPTABLE: Scoped query within the controller's element
    this.element
      .querySelectorAll('[data-modal-target="container"]')
      .forEach(modal => setVisible(modal, false))

    setTimeout(() => {
      this._unlockScroll()
    }, 300)

    setTimeout(() => {
      if (this._formSubmissionInProgress) {
        this._unlockScroll()
        this._formSubmissionInProgress = false
      }
      if (document.body.classList.contains("overflow-hidden")) {
        this._unlockScroll()
      }
    }, 1000)

    const onVisible = () => {
      if (process.env.NODE_ENV !== 'production') {
        console.log("Visibility change: cleaning up")
      }
      this._unlockScroll()
      document.removeEventListener("visibilitychange", onVisible)
    }
    document.addEventListener("visibilitychange", onVisible, { once: true })
  }

  handleTurboSubmitEnd(event) {
    const form = event.detail?.formSubmission?.formElement
    if (form?.closest('[data-modal-target="container"]')) {
      if (process.env.NODE_ENV !== 'production') {
        console.log("Turbo form submission in modal finished")
      }
      this._formSubmissionInProgress = false
      // ✅ ACCEPTABLE: Scoped query within the controller's element
      this.element
        .querySelectorAll('[data-modal-target="container"]')
        .forEach(modal => setVisible(modal, false))

      setTimeout(() => {
        if (!this.preserveScrollValue) {
          this._unlockScroll()
        }
        if (document.body.classList.contains("overflow-hidden")) {
          this._unlockScroll()
        }
      }, 250)
    }
  }

  handleKeydown(event) {
    if (event.key === "Escape") {
      this.close()
    }
  }

  preventClose(event) {
    event.stopPropagation()
  }

  handleSubmit(event) {
    const form = event.target
    const isValid = form.checkValidity()
    const opensNewWindow = form.dataset.opensNewWindow === "true"

    if (!isValid) {
      event.preventDefault()
      form.reportValidity()
    } else if (!opensNewWindow) {
      this.close()
    }
  }
}

// Apply target safety mixin
applyTargetSafety(ModalController)

export default ModalController
