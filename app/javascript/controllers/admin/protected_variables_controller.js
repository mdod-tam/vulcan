import { Controller } from "@hotwired/stimulus"

const BLOCK_ELEMENTS = new Set([
  "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figcaption", "figure",
  "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
  "ol", "p", "pre", "section", "table", "ul"
])
const PLACEHOLDER = /(%<[\w.]+>s|%{[\w.]+}|{{-?\s*[\w.]+\s*-?}})/g

export default class extends Controller {
  static targets = [
    "textarea", "editor", "variableSelect", "syntaxSelect", "subjectInput", "subjectEditor",
    "subjectVariableSelect", "liquidHelp", "convertPanel"
  ]

  connect() {
    this.listeners = new AbortController()
    this.fields = [
      { editor: this.editorTarget, input: this.textareaTarget, picker: this.variableSelectTarget },
      { editor: this.subjectEditorTarget, input: this.subjectInputTarget, picker: this.subjectVariableSelectTarget, singleLine: true }
    ]
    this.labels = new Map(Array.from(this.variableSelectTarget.options, (option) => [option.dataset.variableName, option.textContent.trim()]))
    this.fields.forEach(field => this.connectField(field))
    this.subjectInputTarget.type = "hidden"
    this.subjectEditorTarget.hidden = false
    this.subjectEditorTarget.classList.remove("hidden")
    this.listen(this.element, "submit", () => this.fields.forEach(field => this.syncField(field)), true)

    if (this.hasSyntaxSelectTarget) {
      this.previousSyntax = this.syntaxSelectTarget.value
      this.listen(this.syntaxSelectTarget, "change", () => this.handleSyntaxChange())
      this.updateSyntaxControls()
    }
  }

  disconnect() {
    this.listeners.abort()
    this.draggedDetail = null
  }

  listen(element, event, callback, capture = false) {
    element.addEventListener(event, callback, { capture, signal: this.listeners.signal })
  }

  connectField(field) {
    const { editor, input, picker, singleLine } = field
    this.renderField(field)
    this.listen(input, "change", () => this.renderField(field))
    this.listen(editor, "input", () => {
      this.syncField(field)
      this.rememberSelection(field)
    })
    for (const event of ["focus", "keyup", "mouseup"]) {
      this.listen(editor, event, () => this.rememberSelection(field))
    }
    if (singleLine) {
      this.listen(editor, "beforeinput", (event) => {
        if (["insertParagraph", "insertLineBreak"].includes(event.inputType)) event.preventDefault()
      })
    }
    this.listen(editor, "copy", event => this.copySelection(event, field))
    this.listen(editor, "cut", event => this.copySelection(event, field))
    this.listen(editor, "paste", event => {
      event.preventDefault()
      const text = event.clipboardData?.getData("text/plain")
      if (text) this.replaceSelection(field, text)
    })
    this.listen(editor, "dragstart", event => this.startDrag(event))
    this.listen(editor, "dragend", () => { this.draggedDetail = null })
    this.listen(editor, "dragover", event => event.preventDefault())
    this.listen(editor, "drop", event => this.dropDetail(event, field))
    this.listen(picker, "change", () => {
      if (!picker.value) return
      this.replaceSelection(field, picker.value)
      picker.value = ""
    })
  }

  renderField(field) {
    field.editor.replaceChildren(this.editorContent(field.input.value))
    field.lastRange = null
  }

  editorContent(text) {
    const fragment = document.createDocumentFragment()
    text.split(PLACEHOLDER).forEach((part, index) => {
      if (!part) return
      const name = index % 2 === 1 && part.match(/^%<([\w.]+)>s$|^%{([\w.]+)}$|^{{-?\s*([\w.]+)\s*-?}}$/)?.slice(1).find(Boolean)
      const label = this.labels.get(name)
      if (!label) {
        fragment.append(part)
        return
      }

      const detail = document.createElement("span")
      detail.className = "protected-variable protected-variable-movable"
      detail.setAttribute("contenteditable", "false")
      detail.draggable = true
      detail.dataset.placeholder = part
      detail.textContent = label
      fragment.append(detail)
    })
    return fragment
  }

  rangeInEditor(field, range) {
    return range && field.editor.contains(range.commonAncestorContainer)
  }

  rememberSelection(field) {
    const selection = window.getSelection()
    const range = selection.rangeCount ? selection.getRangeAt(0) : null
    if (this.rangeInEditor(field, range)) field.lastRange = range.cloneRange()
  }

  insertionRange(field) {
    const selection = window.getSelection()
    const current = selection.rangeCount ? selection.getRangeAt(0) : null
    if (this.rangeInEditor(field, current)) return current.cloneRange()
    if (this.rangeInEditor(field, field.lastRange)) return field.lastRange.cloneRange()

    const range = document.createRange()
    range.selectNodeContents(field.editor)
    range.collapse(false)
    return range
  }

  selectRange(editor, range) {
    editor.focus()
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  replaceSelection(field, text, range = this.insertionRange(field)) {
    const value = field.singleLine ? text.replace(/[\r\n]+/g, " ") : text.replace(/\r\n?/g, "\n")
    const content = this.editorContent(value)
    if (!content.hasChildNodes()) return

    this.selectRange(field.editor, range)
    const wrapper = document.createElement("div")
    wrapper.append(content.cloneNode(true))
    // Native insertion keeps the browser's undo history for choices and plain-text paste.
    if (!document.execCommand?.("insertHTML", false, wrapper.innerHTML)) {
      const lastNode = content.lastChild
      range.deleteContents()
      range.insertNode(content)
      range.setStartAfter(lastNode)
      range.collapse(true)
      this.selectRange(field.editor, range)
    }
    this.syncField(field)
    this.rememberSelection(field)
  }

  copySelection(event, field) {
    const selection = window.getSelection()
    if (!event.clipboardData || selection.isCollapsed || !selection.rangeCount) return
    const range = selection.getRangeAt(0)
    if (!this.rangeInEditor(field, range)) return

    event.preventDefault()
    event.clipboardData.setData("text/plain", this.serializeChildren(range.cloneContents()))
    if (event.type === "cut") {
      if (!document.execCommand?.("delete")) range.deleteContents()
      this.syncField(field)
    }
  }

  startDrag(event) {
    const detail = event.target.closest(".protected-variable")
    if (!detail) return
    this.draggedDetail = detail
    event.dataTransfer.effectAllowed = "copyMove"
    event.dataTransfer.setData("text/plain", detail.dataset.placeholder)
  }

  dropDetail(event, field) {
    event.preventDefault()
    const caret = document.caretPositionFromPoint?.(event.clientX, event.clientY)
    const range = caret ? document.createRange() : document.caretRangeFromPoint?.(event.clientX, event.clientY)
    if (caret) range.setStart(caret.offsetNode, caret.offset)
    if (!this.rangeInEditor(field, range)) return
    const detail = this.draggedDetail
    if (detail && field.editor.contains(detail)) {
      if (detail.contains(range.startContainer)) return
      range.insertNode(detail)
      this.syncField(field)
      return
    }

    const text = event.dataTransfer.getData("text/plain")
    if (text) this.replaceSelection(field, text, range)
  }

  syncField(field) {
    const text = this.serializeChildren(field.editor)
      .replace(/\u00a0/g, " ")
    field.input.value = field.singleLine ? text.replace(/[\r\n]+/g, " ") : text.replace(/\n{3,}/g, "\n\n").replace(/\n+$/, "")
  }

  serializeChildren(node) {
    return Array.from(node.childNodes, child => this.serializeNode(child)).join("")
  }

  serializeNode(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent
    if (node.nodeType !== Node.ELEMENT_NODE) return ""
    if (node.classList.contains("protected-variable")) return node.dataset.placeholder
    if (node.localName === "br") return "\n"

    const content = this.serializeChildren(node)
    return BLOCK_ELEMENTS.has(node.localName) && !content.endsWith("\n") ? content + "\n" : content
  }

  handleSyntaxChange() {
    if (this.syntaxSelectTarget.value === "liquid" && this.previousSyntax !== "liquid" && this.hasStandardPlaceholders()) {
      const confirmed = window.confirm("Changing the format leaves the existing details as written. Review them before saving.")
      if (!confirmed) {
        this.syntaxSelectTarget.value = this.previousSyntax
        return
      }
    }
    this.previousSyntax = this.syntaxSelectTarget.value
    this.updateSyntaxControls()
  }

  updateSyntaxControls() {
    const liquid = this.syntaxSelectTarget.value === "liquid"
    for (const { picker } of this.fields) {
      for (const option of picker.options) {
        if (!option.dataset.legacyPlaceholder) continue
        option.disabled = liquid && option.dataset.variableKind === "optional"
        option.value = liquid && !option.disabled ? option.dataset.liquidPlaceholder : option.dataset.legacyPlaceholder
      }
    }
    for (const panel of [...this.liquidHelpTargets, ...this.convertPanelTargets]) {
      panel.classList.toggle("hidden", !liquid)
    }
  }

  convertStandardPlaceholders() {
    const conversions = new Map()
    for (const option of this.variableSelectTarget.options) {
      const { variableName, variableKind, liquidPlaceholder } = option.dataset
      if (variableName && variableKind !== "optional") conversions.set(variableName, liquidPlaceholder)
    }

    let replacements = 0
    for (const field of this.fields) {
      field.input.value = field.input.value.replace(/%<([\w.]+)>s|%{([\w.]+)}/g, (match, named, bare) => {
        const replacement = conversions.get(named || bare)
        if (!replacement) return match
        replacements++
        return replacement
      })
      this.renderField(field)
    }
    if (replacements === 0) window.alert("There are no matching details to convert.")
  }

  hasStandardPlaceholders() {
    return this.fields.some(({ input }) => /%<[\w.]+>s|%{[\w.]+}/.test(input.value))
  }
}
