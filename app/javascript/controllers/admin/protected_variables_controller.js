import { Controller } from "@hotwired/stimulus"

const BLOCK_ELEMENTS = new Set([
  "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figcaption", "figure",
  "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
  "ol", "p", "pre", "section", "table", "ul"
])

export default class extends Controller {
  static targets = [
    "textarea", "editor", "variableSelect", "syntaxSelect", "subjectInput", "subjectVariableSelect",
    "standardHelp", "liquidHelp", "convertPanel"
  ]
  
  connect() {
    this.previousSyntax = this.hasSyntaxSelectTarget ? this.syntaxSelectTarget.value : null
    this.lastEditorRange = null
    this.renderProtectedVariables()
    this.element.addEventListener("submit", () => this.syncToTextarea())
    this.editorTarget.addEventListener("input", () => {
      this.syncToTextarea()
      this.rememberEditorSelection()
    })
    this.editorTarget.addEventListener("focus", () => this.rememberEditorSelection())
    this.editorTarget.addEventListener("click", () => this.rememberEditorSelection())
    this.editorTarget.addEventListener("keyup", () => this.rememberEditorSelection())
    this.editorTarget.addEventListener("mouseup", () => this.rememberEditorSelection())
    this.editorTarget.addEventListener("keydown", (e) => this.handleKeydown(e))
    this.editorTarget.addEventListener("paste", (e) => this.handlePaste(e))
    this.editorTarget.addEventListener("dragover", (e) => this.handleDragOver(e))
    this.editorTarget.addEventListener("drop", (e) => this.handleDrop(e))
    this.textareaTarget.addEventListener("change", () => this.renderProtectedVariables())
    // Handle variable dropdown selection
    this.variableSelectTarget.addEventListener("change", (e) => this.insertVariable(e))
    if (this.hasSubjectVariableSelectTarget) {
      this.subjectVariableSelectTarget.addEventListener("change", (e) => this.insertSubjectVariable(e))
    }
    if (this.hasSyntaxSelectTarget) {
      this.syntaxSelectTarget.addEventListener("change", () => this.handleSyntaxChange())
      this.updateVariableOptions()
      this.updateSyntaxHelp()
    }
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

  handlePaste(e) {
    e.preventDefault()
    const text = e.clipboardData?.getData("text/plain") || ""
    if (!text) return

    this.insertTextAtSelection(text)
    this.syncToTextarea()
  }

  insertVariable(e) {
    const variableText = e.target.value
    if (!variableText) return

    const range = this.rangeForVariableInsertion()

    // Create a span for the variable
    const span = document.createElement('span')
    span.className = 'protected-variable'
    span.draggable = true
    span.contentEditable = false
    span.style.cssText = 'background-color: #e5e7eb; color: #6b7280; padding: 2px 4px; border-radius: 3px; cursor: move; user-select: none;'
    span.textContent = variableText

    // Insert at cursor
    range.deleteContents()
    range.insertNode(span)

    // Add drag listeners
    span.addEventListener('dragstart', (e) => this.handleDragStart(e))
    span.addEventListener('dragend', (e) => this.handleDragEnd(e))

    this.moveCursorAfter(span)

    // Reset dropdown
    e.target.value = ''

    // Sync to textarea
    this.syncToTextarea()
  }

  insertSubjectVariable(e) {
    const variableText = e.target.value
    if (!variableText || !this.hasSubjectInputTarget) return

    const input = this.subjectInputTarget
    const start = input.selectionStart ?? input.value.length
    const end = input.selectionEnd ?? start

    input.value = `${input.value.slice(0, start)}${variableText}${input.value.slice(end)}`
    input.focus()
    input.setSelectionRange(start + variableText.length, start + variableText.length)
    input.dispatchEvent(new Event("input", { bubbles: true }))
    e.target.value = ""
  }

  handleSyntaxChange() {
    if (this.syntaxSelectTarget.value === "liquid" && this.previousSyntax !== "liquid" && this.hasStandardPlaceholders()) {
      const confirmed = window.confirm("Existing Standard placeholders will not convert. Re-insert variables from the dropdown after switching.")
      if (!confirmed) {
        this.syntaxSelectTarget.value = this.previousSyntax
        this.updateVariableOptions()
        return
      }
    }

    this.previousSyntax = this.syntaxSelectTarget.value
    this.updateVariableOptions()
    this.updateSyntaxHelp()
  }

  updateVariableOptions() {
    const syntax = this.syntaxSelectTarget.value

    this.updateSelectOptions(this.variableSelectTarget, syntax)
    if (this.hasSubjectVariableSelectTarget) {
      this.updateSelectOptions(this.subjectVariableSelectTarget, syntax)
    }
  }

  updateSelectOptions(select, syntax) {
    Array.from(select.options).forEach((option) => {
      if (!option.dataset.legacyPlaceholder) return

      option.disabled = syntax === "liquid" && option.dataset.variableKind === "optional"
      option.value = syntax === "liquid" && !option.disabled ? option.dataset.liquidPlaceholder : option.dataset.legacyPlaceholder
      option.textContent = syntax === "liquid" && !option.disabled ? option.dataset.liquidLabel : option.dataset.legacyLabel
      if (option.disabled) option.textContent = `${option.dataset.legacyLabel} (Standard only)`
    })
  }

  updateSyntaxHelp() {
    const syntax = this.syntaxSelectTarget.value

    this.toggleTarget(this.standardHelpTargets, syntax !== "liquid")
    this.toggleTarget(this.liquidHelpTargets, syntax === "liquid")
    this.toggleTarget(this.convertPanelTargets, syntax === "liquid")
  }

  toggleTarget(targets, visible) {
    targets.forEach((target) => target.classList.toggle("hidden", !visible))
  }

  convertStandardPlaceholders() {
    const conversions = this.placeholderConversions()
    let replacements = 0

    if (this.hasSubjectInputTarget) {
      const [convertedSubject, subjectReplacements] = this.convertText(this.subjectInputTarget.value, conversions)
      this.subjectInputTarget.value = convertedSubject
      replacements += subjectReplacements
    }

    const [convertedBody, bodyReplacements] = this.convertText(this.textareaTarget.value, conversions)
    this.textareaTarget.value = convertedBody
    replacements += bodyReplacements

    this.renderProtectedVariables()
    if (replacements === 0) {
      window.alert("No matching Standard placeholders were found.")
    }
  }

  placeholderConversions() {
    const conversions = new Map()

    Array.from(this.variableSelectTarget.options).forEach((option) => {
      if (!option.dataset.legacyPlaceholder || !option.dataset.liquidPlaceholder || !option.dataset.variableName) return
      if (option.dataset.variableKind === "optional") return

      conversions.set(option.dataset.variableName, option.dataset.liquidPlaceholder)
    })

    return conversions
  }

  convertText(text, conversions) {
    let replacements = 0
    const converted = text.replace(/%[<{]([a-zA-Z_][a-zA-Z0-9_]*)[>}]s?/g, (match, name) => {
      if (!conversions.has(name)) return match

      replacements += 1
      return conversions.get(name)
    })

    return [converted, replacements]
  }

  hasStandardPlaceholders() {
    const subject = this.hasSubjectInputTarget ? this.subjectInputTarget.value : ""
    const body = this.textareaTarget.value
    return /%[<{][a-zA-Z_][a-zA-Z0-9_]*[>}]s?/.test(`${subject}\n${body}`)
  }

  insertTextAtSelection(text) {
    const selection = window.getSelection()
    if (!selection.rangeCount) {
      this.editorTarget.appendChild(document.createTextNode(text))
      return
    }

    const range = selection.getRangeAt(0)
    range.deleteContents()
    const textNode = document.createTextNode(text)
    range.insertNode(textNode)
    range.setStartAfter(textNode)
    range.collapse(true)
    selection.removeAllRanges()
    selection.addRange(range)
  }

  rememberEditorSelection() {
    const selection = window.getSelection()
    if (!selection.rangeCount) return

    const range = selection.getRangeAt(0)
    if (!this.rangeBelongsToEditor(range)) return

    this.lastEditorRange = range.cloneRange()
  }

  rangeForVariableInsertion() {
    const selection = window.getSelection()

    if (selection.rangeCount > 0) {
      const range = selection.getRangeAt(0)
      if (this.rangeBelongsToEditor(range)) {
        this.lastEditorRange = range.cloneRange()
        return range
      }
    }

    if (this.lastEditorRange && this.rangeBelongsToEditor(this.lastEditorRange)) {
      const restoredRange = this.lastEditorRange.cloneRange()
      selection.removeAllRanges()
      selection.addRange(restoredRange)
      return restoredRange
    }

    const endRange = document.createRange()
    endRange.selectNodeContents(this.editorTarget)
    endRange.collapse(false)
    selection.removeAllRanges()
    selection.addRange(endRange)
    this.lastEditorRange = endRange.cloneRange()
    return endRange
  }

  rangeBelongsToEditor(range) {
    const container = range.commonAncestorContainer
    return container === this.editorTarget || this.editorTarget.contains(container)
  }

  moveCursorAfter(node) {
    const selection = window.getSelection()
    const range = document.createRange()
    range.setStartAfter(node)
    range.collapse(true)
    selection.removeAllRanges()
    selection.addRange(range)
    this.lastEditorRange = range.cloneRange()
    this.editorTarget.focus()
  }

  
  renderProtectedVariables() {
    const text = this.textareaTarget.value
    
    // Split text into parts: variables and regular text
    const variablePattern = /(%<[a-zA-Z0-9_.]+>s|\{\{\-?\s*[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*\s*\-?\}\})/g
    const parts = text.split(variablePattern)
    
    // Create HTML with variables as non-editable and text as editable
    const html = parts.map((part) => {
      if (part.match(/^%<[a-zA-Z0-9_.]+>s$/) || part.match(/^\{\{\-?\s*[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*\s*\-?\}\}$/)) {
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
  }

  syncToTextarea() {
    const content = this.serializeEditorChildren(this.editorTarget)
      .replace(/\u00a0/g, " ")
      .replace(/\n{3,}/g, "\n\n")
      .replace(/\n+$/, "")

    this.textareaTarget.value = content
  }

  serializeEditorChildren(node) {
    return Array.from(node.childNodes)
      .map(child => this.serializeEditorNode(child))
      .join("")
  }

  serializeEditorNode(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent
    if (node.nodeType !== Node.ELEMENT_NODE) return ""
    if (node.classList?.contains("protected-variable")) return node.textContent
    if (node.tagName.toLowerCase() === "br") return "\n"

    const content = this.serializeEditorChildren(node)
    if (BLOCK_ELEMENTS.has(node.tagName.toLowerCase())) {
      return content.endsWith("\n") ? content : `${content}\n`
    }

    return content
  }
  
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
