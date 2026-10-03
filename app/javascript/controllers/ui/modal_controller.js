import { Controller } from "@hotwired/stimulus"

class ModalController extends Controller {
  static targets = ["container"]

  connect() {
    this._handleTurboSubmitEnd = this.handleTurboSubmitEnd.bind(this)
    
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

    // A rejection modal takes its proof type from the button that opens it.
    const proofType = event.currentTarget.dataset.proofType
    if (proofType) {
      this._setProofTypeInModal(dialog, proofType)
    }

    if (dialog.tagName === "DIALOG") {
      dialog.showModal()
      this._loadIframes(dialog)
      
      // Test hook. No current test reads it.
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
      dialog.removeAttribute('data-test-modal-ready')
    }
  }

  clickOutside(event) {
    if (event.target === event.currentTarget) {
      event.currentTarget.close()
    }
  }
  
  onClose(event) {
      // showModal() makes the page inert and close() restores it, so this handler only clears the test hook.
      const dialog = event.target
      dialog.removeAttribute('data-test-modal-ready')
  }

  handleTurboSubmitEnd(event) {
    if (event.detail.success) {
      const form = event.target
      const dialog = form.closest("dialog")
      if (dialog) {
        dialog.close()
        dialog.removeAttribute('data-test-modal-ready')
      }
    }
  }

  _setProofTypeInModal(modalElement, proofType) {
    const proofTypeField = modalElement.querySelector('#rejection-proof-type, #medical-rejection-proof-type')
    if (proofTypeField) {
      proofTypeField.value = proofType
      
      proofTypeField.dispatchEvent(new Event('change', { bubbles: true }))
      
      // The rejection-form controller can be on the modal or inside it.
      const formElement = modalElement.hasAttribute('data-controller') && modalElement.getAttribute('data-controller').includes('rejection-form')
        ? modalElement
        : modalElement.querySelector('[data-controller*="rejection-form"]')
        
      if (formElement) {
        formElement.dispatchEvent(new CustomEvent('proof-type-changed', { 
          detail: { proofType },
          bubbles: true 
        }))
      }
    }
  }

  _loadIframes(element) {
    const iframes = element.querySelectorAll('iframe[data-original-src]')
    
    iframes.forEach((iframe) => {
      const originalSrc = iframe.getAttribute("data-original-src")
      if (!originalSrc) return

      if (!iframe.src || iframe.src === 'about:blank') {
         iframe.src = originalSrc + '&t=' + new Date().getTime()
      } else {
         // A reopened dialog can show a blank PDF. Reassigning src makes the browser fetch and render it again.
         iframe.src = iframe.src 
      }
    })
  }
}

export default ModalController
