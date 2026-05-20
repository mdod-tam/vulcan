import { Controller } from "@hotwired/stimulus"

// Moves keyboard focus into the error summary on render and to the referenced
// field when a summary link is activated, so screen readers and keyboard users
// reliably learn that validation failed (WCAG 2.4.3 Focus Order, 3.3.1 Error
// Identification).
export default class extends Controller {
  connect() {
    if (!this.element.hasAttribute("tabindex")) {
      this.element.setAttribute("tabindex", "-1")
    }

    requestAnimationFrame(() => {
      try {
        this.element.focus({ preventScroll: false })
      } catch (_) {
        this.element.focus()
      }
    })
  }

  focus(event) {
    const link = event.currentTarget
    const href = link.getAttribute("href") || ""
    if (!href.startsWith("#")) return

    const id = decodeURIComponent(href.slice(1))
    if (!id) return

    const target = document.getElementById(id)
    if (!target) return

    event.preventDefault()

    if (target.tabIndex < 0 && !target.matches("input, select, textarea, button, a[href]")) {
      target.setAttribute("tabindex", "-1")
    }

    target.focus({ preventScroll: false })

    if (typeof history !== "undefined" && history.replaceState) {
      history.replaceState(null, "", `#${id}`)
    }
  }
}
