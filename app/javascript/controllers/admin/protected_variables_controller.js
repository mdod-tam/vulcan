import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea", "editor"]
  
  connect() {
    this.renderProtectedVariables()
    this.editorTarget.addEventListener("input", () => {
      this.syncToTextarea()
      this.renderProtectedVariables()
    })
    this.editorTarget.addEventListener("keydown", (e) => this.preventCursorInVariable(e))
    this.textareaTarget.addEventListener("change", () => this.renderProtectedVariables())
  }
  
  preventCursorInVariable(e) {
    // Only prevent if directly clicking on a protected variable
    if (e.target.classList?.contains("protected-variable")) {
      e.preventDefault()
      
      // Move cursor to after the variable
      const selection = window.getSelection()
      const range = document.createRange()
      const nextNode = e.target.nextSibling || e.target.parentNode.nextSibling
      
      if (nextNode) {
        range.setStart(nextNode, 0)
      } else {
        range.setStart(this.editorTarget, this.editorTarget.childNodes.length)
      }
      range.collapse(true)
      selection.removeAllRanges()
      selection.addRange(range)
    }
  }
  
  renderProtectedVariables() {
    const text = this.textareaTarget.value
    
    // Split text into parts: variables and regular text
    const parts = text.split(/(%<[a-zA-Z0-9_]+>s)/g)
    
    // Create HTML with variables as non-editable and text as editable
    const html = parts.map((part) => {
      if (part.match(/^%<[a-zA-Z0-9_]+>s$/)) {
        // This is a variable - make it non-editable with grey background
        return `<span class="protected-variable" contenteditable="false" style="background-color: #e5e7eb; color: #6b7280; padding: 2px 4px; border-radius: 3px; cursor: not-allowed; user-select: none;">${this.escapeHtml(part)}</span>`
      } else {
        // This is regular text - keep it editable
        return this.escapeHtml(part)
      }
    }).join("")
    
    this.editorTarget.innerHTML = html
  }
  
  syncToTextarea() {
    // Extract all text content, preserving variable spans
    const content = Array.from(this.editorTarget.childNodes)
      .map(node => {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent
        if (node.classList?.contains("protected-variable")) return node.textContent
        return node.textContent
      })
      .join("")
    this.textareaTarget.value = content
  }
  
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}