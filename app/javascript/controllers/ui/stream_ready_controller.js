import { Controller } from "@hotwired/stimulus"

// Sets a data attribute when the element is connected/reconnected by Turbo streams
export default class extends Controller {
  connect() {
    try {
      const ts = Date.now().toString()
      // Prefer setting the attribute on the attachments section wrapper if present
      const target = this.element.closest('#attachments-section') || this.element
      target.setAttribute('data-test-rendered-at', ts)
    } catch (_) {
      // no-op
    }
  }
}


