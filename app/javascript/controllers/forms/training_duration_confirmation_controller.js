import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { message: String }
  static targets = ["dialog", "duration", "message", "yesButton", "noButton", "submitButton"]

  connect() {
    this.confirmed = false
  }

  confirm(event) {
    if (this.confirmed) {
      return
    }

    const duration = Number.parseFloat(this.durationTarget.value)
    if (Number.isNaN(duration) || duration <= 2) {
      return
    }

    event.preventDefault()
    this.messageTarget.textContent = this.messageValue.replace("__HOURS__", this.formatDuration(duration))
    this.openDialog()
  }

  proceed() {
    this.confirmed = true
    this.closeDialog()
    try {
      this.element.requestSubmit(this.submitButtonTarget)
    } finally {
      this.confirmed = false
    }
  }

  cancel(event) {
    event?.preventDefault()
    this.closeDialog()
    this.durationTarget.focus()
  }

  openDialog() {
    if (typeof this.dialogTarget.showModal === "function") {
      this.dialogTarget.showModal()
    } else {
      this.dialogTarget.setAttribute("open", "open")
    }

    this.noButtonTarget.focus()
  }

  closeDialog() {
    if (this.dialogTarget.open && typeof this.dialogTarget.close === "function") {
      this.dialogTarget.close()
    } else {
      this.dialogTarget.removeAttribute("open")
    }
  }

  formatDuration(duration) {
    return duration.toString()
  }
}
