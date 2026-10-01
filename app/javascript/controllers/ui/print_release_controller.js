import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static targets = ["all", "letter", "submit", "status"]

  connect() {
    this.selectionChanged()
  }

  selectAll() {
    this.letterTargets.forEach(letter => { letter.checked = this.allTarget.checked })
    this.selectionChanged()
  }

  selectionChanged() {
    const selected = this.letterTargets.filter(letter => letter.checked).length
    if (this.hasAllTarget) {
      this.allTarget.checked = selected > 0 && selected === this.letterTargets.length
      this.allTarget.indeterminate = selected > 0 && selected < this.letterTargets.length
    }
    this.submitTargets.forEach(button => { button.disabled = selected === 0 })
  }

  async download(event) {
    if (event.submitter?.hasAttribute("formaction")) return
    event.preventDefault()
    if (this.busy) return

    this.busy = true
    const body = new FormData(this.element)
    const controls = [...this.element.querySelectorAll('input:not([type="hidden"]), button')]
      .map(control => [control, control.disabled])
    controls.forEach(([control]) => { control.disabled = true })
    this.element.setAttribute("aria-busy", "true")
    this.statusTarget.textContent = "Preparing download…"
    try {
      const response = await fetch(this.element.action, {
        method: "POST", body, credentials: "same-origin",
        headers: { Accept: "text/vnd.turbo-stream.html, text/html" }
      })
      if (!response.ok) {
        if (response.headers.get("Content-Type")?.includes("text/vnd.turbo-stream.html")) {
          Turbo.renderStreamMessage(await response.text())
          requestAnimationFrame(() => document.querySelector("[data-print-release-error]")?.focus())
          return
        }
        throw new Error("Download refused")
      }
      const disposition = response.headers.get("Content-Disposition") || ""
      if (!disposition.startsWith("attachment")) throw new Error("Unexpected download response")
      const filename = disposition.match(/filename="([^"\r\n]+)"/)?.[1] || "letters.pdf"
      const url = URL.createObjectURL(await response.blob())
      const link = document.createElement("a")
      link.href = url
      link.download = filename
      document.body.appendChild(link)
      link.click()
      link.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      if (this.element.isConnected) Turbo.visit(window.location.href, { action: "replace" })
    } catch (_error) {
      this.statusTarget.textContent = "The download could not be confirmed. Refresh the queue to check release status, then try downloading again."
    } finally {
      this.busy = false
      controls.forEach(([control, disabled]) => { control.disabled = disabled })
      this.element.removeAttribute("aria-busy")
    }
  }
}
