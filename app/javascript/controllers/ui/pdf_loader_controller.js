import { Controller } from "@hotwired/stimulus"

// This controller handles deferred loading of PDF files to ensure page components are fully initialized
export default class extends Controller {
  static targets = ["placeholder", "container"]
  static values = { pdfUrl: String }
  
  connect() {
    if (process.env.NODE_ENV !== 'production') {
      console.log("PDF Loader controller connected")
    }
  }
  
  // Load the PDF when user explicitly requests it
  loadPdf() {
    if (!this.pdfUrlValue) {
      console.error("PDF URL is missing")
      // Show inline error message within the placeholder area
      if (this.hasPlaceholderTarget) {
        // Clear placeholder and insert error
        this.placeholderTarget.innerHTML = ''
        const errorContainer = document.createElement('div')
        errorContainer.className = 'p-4 bg-red-50 border border-red-100 rounded my-2'
        errorContainer.setAttribute('role', 'alert')
        errorContainer.innerHTML = `
          <p class="text-red-800 font-medium">Error loading PDF</p>
          <p class="text-red-600 text-sm">The PDF URL is missing. Please contact support.</p>
        `
        this.placeholderTarget.appendChild(errorContainer)
        this.placeholderTarget.classList.remove('hidden')
      }
      if (this.hasContainerTarget) {
        this.containerTarget.classList.add('hidden')
      }
      return
    }
    
    // Create iframe
    const iframe = document.createElement('iframe')
    iframe.src = this.pdfUrlValue
    iframe.type = "application/pdf"
    iframe.className = "w-full h-full"
    iframe.setAttribute('data-turbo', 'false')
    iframe.setAttribute('allow', 'fullscreen')
    
    // Add to container and show
    this.containerTarget.appendChild(iframe)
    this.containerTarget.classList.remove('hidden')
    this.placeholderTarget.classList.add('hidden')
    
    // Dispatch event that PDF loading has started
    this.element.dispatchEvent(new CustomEvent('pdf-loader:loaded'))
  }
}
