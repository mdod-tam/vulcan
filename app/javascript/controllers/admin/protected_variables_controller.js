import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea", "editor", "variableSelect"]
  
  connect() {
    this.renderProtectedVariables()
    this.editorTarget.addEventListener("input", () => {
      this.syncToTextarea()
    })
    this.editorTarget.addEventListener("keydown", (e) => this.handleKeydown(e))
    this.textareaTarget.addEventListener("change", () => this.renderProtectedVariables())
    // Handle variable dropdown selection
    this.variableSelectTarget.addEventListener("change", (e) => this.insertVariable(e))
  }
  
  handleKeydown(e) {
    // Allow deleting selected variables with backspace/delete
    if ((e.key === 'Backspace' || e.key === 'Delete') && e.target.classList?.contains('protected-variable')) {
      e.preventDefault()
      e.target.remove()
      this.syncToTextarea()
      return
    }
    
    // Prevent cursor inside variables
    this.preventCursorInVariable(e)
  }
  
  preventCursorInVariable(e) {
    console.log('preventCursorInVariable')
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

  handleDragStart(e) {
    e.dataTransfer.effectAllowed = 'move'
    e.dataTransfer.setData('text/html', e.target.outerHTML)
    e.dataTransfer.setData('text/plain', e.target.textContent)
    // Store reference to the original element so we can remove it later
    this.draggedElement = e.target
    e.target.style.opacity = '0.5'
  }
  
  handleDragEnd(e) {
    e.target.style.opacity = '1'
  }
  
  handleDragOver(e) {
    e.preventDefault()
    // Only allow dropping on text nodes or the editor itself, not on other variables
    if (e.target === this.editorTarget || (e.target.nodeType === Node.TEXT_NODE)) {
      e.dataTransfer.dropEffect = 'move'
    } else if (!e.target.classList?.contains('protected-variable')) {
      e.dataTransfer.dropEffect = 'move'
    } else {
      e.dataTransfer.dropEffect = 'none'
    }
  }
  
  handleDrop(e) {
    e.preventDefault()
    
    // Don't allow dropping into other variables
    if (e.target.classList?.contains('protected-variable')) {
      return
    }
    
    e.target.style.opacity = '1'
    
    // Get the variable text being dragged
    const variableText = e.dataTransfer.getData('text/plain')
    
    // Get the position where we dropped
    const range = document.caretRangeFromPoint(e.clientX, e.clientY)
    
    if (range && (range.commonAncestorContainer.parentElement === this.editorTarget || this.editorTarget.contains(range.commonAncestorContainer))) {
      // Create a new span for the variable
      const span = document.createElement('span')
      span.className = 'protected-variable'
      span.draggable = true
      span.contentEditable = false
      span.style.cssText = 'background-color: #e5e7eb; color: #6b7280; padding: 2px 4px; border-radius: 3px; cursor: move; user-select: none;'
      span.textContent = variableText
      
      // Insert at the drop position
      range.insertNode(span)
      
      // Add drag listeners to the new variable
      span.addEventListener('dragstart', (e) => this.handleDragStart(e))
      span.addEventListener('dragend', (e) => this.handleDragEnd(e))
      
      // Remove the original variable if it's different from the new one
      if (this.draggedElement && this.draggedElement !== span) {
        this.draggedElement.remove()
      }

      // Sync to textarea
      this.syncToTextarea()      
    }
    
    this.draggedElement = null
  }

  insertVariable(e) {
    const variableText = e.target.value
    if (!variableText) return
    
    // Focus the editor
    this.editorTarget.focus()
    
    // Get current selection/cursor position
    const selection = window.getSelection()
    if (selection.rangeCount === 0) return
    
    const range = selection.getRangeAt(0)
    
    // Create a span for the variable
    const span = document.createElement('span')
    span.className = 'protected-variable'
    span.draggable = true
    span.contentEditable = false
    span.style.cssText = 'background-color: #e5e7eb; color: #6b7280; padding: 2px 4px; border-radius: 3px; cursor: move; user-select: none;'
    span.textContent = variableText
    
    // Insert at cursor
    range.insertNode(span)
    
    // Add drag listeners
    span.addEventListener('dragstart', (e) => this.handleDragStart(e))
    span.addEventListener('dragend', (e) => this.handleDragEnd(e))
    
    // Reset dropdown
    e.target.value = ''
    
    // Sync to textarea
    this.syncToTextarea()
  }

  
  renderProtectedVariables() {
    const text = this.textareaTarget.value
    
    // Split text into parts: variables and regular text
    const parts = text.split(/(%<[a-zA-Z0-9_]+>s)/g)
    
    // Create HTML with variables as non-editable and text as editable
    const html = parts.map((part) => {
      if (part.match(/^%<[a-zA-Z0-9_]+>s$/)) {
        // This is a variable - make it non-editable with grey background
        return `<span class="protected-variable" draggable="true" contenteditable="false" style="background-color: #e5e7eb; color: #6b7280; padding: 2px 4px; border-radius: 3px; cursor: not-allowed; user-select: none;">${this.escapeHtml(part)}</span>`
      } else {
        // This is regular text - keep it editable
        return this.escapeHtml(part)
      }
    }).join("")
    
    this.editorTarget.innerHTML = html
    // Add drag event listeners to all protected variables
    this.editorTarget.querySelectorAll('.protected-variable').forEach(variable => {
      variable.addEventListener('dragstart', (e) => this.handleDragStart(e))
      variable.addEventListener('dragend', (e) => this.handleDragEnd(e))
    })

    // Add drop zone listeners to editor
    this.editorTarget.addEventListener('dragover', (e) => this.handleDragOver(e))
    this.editorTarget.addEventListener('drop', (e) => this.handleDrop(e))
  }

  syncToTextarea() {
    // Extract all text content, preserving variable spans
    const content = Array.from(this.editorTarget.childNodes)
      .map(node => {
        if (node.nodeType === Node.TEXT_NODE) return node.textContent
        if (node.classList?.contains("protected-variable")) return node.textContent
        return node.textContent
     }).join("")
    this.textareaTarget.value = content
  }
  
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}