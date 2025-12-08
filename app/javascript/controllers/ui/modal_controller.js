import { Controller } from "@hotwired/stimulus"

// Declare targets and values for better structure
class ModalController extends Controller {
  static targets = ["container"]

  connect() {
    // Bind methods
    this._handleTurboSubmitEnd = this.handleTurboSubmitEnd.bind(this)
    
    // Listen for turbo submit events within this controller's scope
    this.element.addEventListener("turbo:submit-end", this._handleTurboSubmitEnd)

    if (process.env.NODE_ENV !== 'production') {
      console.log("Modal controller connected (Dialog version)")
    }
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this._handleTurboSubmitEnd)
  }

  open(event) {
    const modalId = event.currentTarget.dataset.modalId
    const dialog = document.getElementById(modalId)
    
    if (!dialog) {
      console.error("ModalController: could not find modal element", modalId)
      return
    }

    // Transfer proof type data from the triggering button to rejection modals
    const proofType = event.currentTarget.dataset.proofType
    if (proofType) {
      this._setProofTypeInModal(dialog, proofType)
    }

    if (dialog.tagName === "DIALOG") {
      dialog.showModal()
      this._loadIframes(dialog)
      
      // Signal for tests
      dialog.setAttribute('data-test-modal-ready', 'true')
    } else {
      console.warn("Modal target is not a <dialog> element:", dialog)
    }
  }

  close(event) {
    event?.preventDefault()
    const dialog = event.target.closest("dialog")
    if (dialog) {
      dialog.close()
      // Remove test attribute on modal close
      dialog.removeAttribute('data-test-modal-ready')
    }
  }

  clickOutside(event) {
    if (event.target === event.currentTarget) {
      event.currentTarget.close()
    }
  }
  
  onClose(event) {
      // With native <dialog> + showModal():
      // - Scroll blocking is handled by the browser
      // - The ::backdrop and inert behavior prevent background interaction
      // - close() automatically restores normal page interaction
      //
      // This handler now only cleans up test attributes.
      const dialog = event.target
      dialog.removeAttribute('data-test-modal-ready')
  }

  handleTurboSubmitEnd(event) {
    if (event.detail.success) {
      const form = event.target
      const dialog = form.closest("dialog")
      if (dialog) {
        dialog.close()
        // Remove test attribute on modal close
        dialog.removeAttribute('data-test-modal-ready')
      }
    }
  }

  _setProofTypeInModal(modalElement, proofType) {
    // Find the hidden proof type field in the rejection modal
    const proofTypeField = modalElement.querySelector('#rejection-proof-type, #medical-rejection-proof-type')
    if (proofTypeField) {
      proofTypeField.value = proofType
      
      // Trigger change event for any listeners
      proofTypeField.dispatchEvent(new Event('change', { bubbles: true }))
      
      // Try to find and notify the rejection form controller
      const formElement = modalElement.hasAttribute('data-controller') && modalElement.getAttribute('data-controller').includes('rejection-form')
        ? modalElement
        : modalElement.querySelector('[data-controller*="rejection-form"]')
        
      if (formElement) {
        // Dispatch a custom event that the rejection form controller can listen for
        formElement.dispatchEvent(new CustomEvent('proof-type-changed', { 
          detail: { proofType },
          bubbles: true 
        }))
      }
    }
  }

  _loadIframes(element) {
    // Scoped query within the modal element for dynamic PDF content
    const iframes = element.querySelectorAll('iframe[data-original-src]')
    
    iframes.forEach((iframe) => {
      const originalSrc = iframe.getAttribute("data-original-src")
      if (!originalSrc) return

      // Set src if missing (first load) or force reload if needed
      // With dialog, we might not need to force reload as aggressively, 
      // but we ensure src is set.
      
      // Check if already loaded to avoid double loading loop if we were to remove this check
      // But for PDFs, sometimes re-setting src is needed. 
      // Let's stick to the simpler logic: ensure src is set.
      
      if (!iframe.src || iframe.src === 'about:blank') {
         iframe.src = originalSrc + '&t=' + new Date().getTime()
      } else {
         // Force reload for PDFs to ensure they render when dialog reopens.
         // Setting iframe.src to itself triggers the browser to re-fetch and
         // re-render the PDF content. Without this, PDFs may appear blank when
         // a dialog is reopened after being closed.
         iframe.src = iframe.src 
      }
    })
  }
}

export default ModalController
