import { Controller } from "@hotwired/stimulus"

// Loads a PDF into an iframe when the user asks for it, not on page load.
export default class extends Controller {
  static targets = ["placeholder", "container"]
  static values = { pdfUrl: String }
  
  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("PDF Loader controller connected")
    }
  }
  
  loadPdf() {
    if (!this.pdfUrlValue) {
      console.error("PDF URL is missing")
      if (this.hasPlaceholderTarget) {
        this.placeholderTarget.innerHTML = ''
        const errorContainer = document.createElement('div')
        errorContainer.className = 'p-4 bg-danger-50 border border-danger-100 rounded my-2'
        errorContainer.setAttribute('role', 'alert')
        errorContainer.innerHTML = `
          <p class="text-danger-800 font-medium">Error loading PDF</p>
          <p class="text-danger-600 text-sm">The PDF URL is missing. Please contact support.</p>
        `
        this.placeholderTarget.appendChild(errorContainer)
        this.placeholderTarget.classList.remove('hidden')
      }
      if (this.hasContainerTarget) {
        this.containerTarget.classList.add('hidden')
      }
      return
    }
    
    const iframe = document.createElement('iframe')
    iframe.src = this.pdfUrlValue
    iframe.type = "application/pdf"
    iframe.className = "w-full h-full"
    iframe.setAttribute('data-turbo', 'false')
    iframe.setAttribute('allow', 'fullscreen')
    
    this.containerTarget.appendChild(iframe)
    this.containerTarget.classList.remove('hidden')
    this.placeholderTarget.classList.add('hidden')
    
    this.element.dispatchEvent(new CustomEvent('pdf-loader:loaded'))
  }
}
