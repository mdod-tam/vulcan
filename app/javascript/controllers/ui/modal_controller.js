import { Controller } from "@hotwired/stimulus"

class ModalController extends Controller {
  static targets = ["container"]

  // A dialog rendered by the server on this element opens itself when it connects.
  static values = { autoOpen: Boolean }

  connect() {
    this._handleTurboSubmitStart = this.handleTurboSubmitStart.bind(this)
    this._handleTurboSubmitEnd = this.handleTurboSubmitEnd.bind(this)
    
    this.element.addEventListener("turbo:submit-start", this._handleTurboSubmitStart)
    this.element.addEventListener("turbo:submit-end", this._handleTurboSubmitEnd)

    if (this.autoOpenValue && this.element.tagName === "DIALOG" && !this.element.open) {
      this.element.showModal()
    }

    if (process.env.NODE_ENV !== 'production') {
      console.log("Modal controller connected")
    }
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-start", this._handleTurboSubmitStart)
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
    } else {
      console.warn("Modal target is not a <dialog> element:", dialog)
    }
  }

  // A dialog stays open while its form is submitting, so a dismissal cannot hide an unfinished request.
  close(event) {
    event?.preventDefault()
    const dialog = event.target.closest("dialog")
    if (dialog && !dialog.dataset.busy) {
      dialog.close()
    }
  }

  clickOutside(event) {
    if (event.target === event.currentTarget && !event.currentTarget.dataset.busy) {
      event.currentTarget.close()
    }
  }

  // Escape fires a cancel event first.
  guardCancel(event) {
    if (event.currentTarget.dataset.busy) event.preventDefault()
  }
  
  onClose(event) {
      // Tells listeners the dialog closed, whether by Escape, the backdrop, or close().
      const dialog = event.target
      window.dispatchEvent(new CustomEvent("modal:closed", { detail: { dialog } }))
  }

  handleTurboSubmitStart(event) {
    const dialog = event.target.closest("dialog")
    if (dialog) dialog.dataset.busy = "true"
  }

  handleTurboSubmitEnd(event) {
    const dialog = event.target.closest("dialog")
    if (dialog) delete dialog.dataset.busy

    if (event.detail.success) {
      if (dialog) {
        dialog.close()
      }
    } else if (dialog && !event.detail.fetchResponse) {
      // No response arrived, so the server may or may not have applied the request.
      dialog.querySelector("[data-modal-unknown-outcome]")?.removeAttribute("hidden")
    }
  }

  _setProofTypeInModal(modalElement, proofType) {
    const proofTypeField = modalElement.querySelector('#rejection-proof-type, #disability-certification-rejection-proof-type')
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
