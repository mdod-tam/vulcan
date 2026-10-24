import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["document", "error"]

  start() {
    this.errorTarget.textContent = ""
    this.errorTarget.hidden = true
  }

  receive(event) {
    if (event.source !== this.documentTarget.contentWindow || event.origin !== "null") return
    if (event.data?.type !== "mat-vulcan:email-preview" || typeof event.data.failed !== "boolean") return

    this.errorTarget.textContent = event.data.failed
      ? "Preview unavailable. Review the error below, correct the draft, and try again."
      : ""
    this.errorTarget.hidden = !event.data.failed
  }
}
