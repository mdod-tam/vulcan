import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "duration", "message", "yesButton", "noButton"]

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
    this.messageTarget.textContent = `You entered more than the typical number of training hours. Confirm ${this.formatDuration(duration)} hours?`
    this.openDialog()
  }

  proceed() {
    this.confirmed = true
    this.closeDialog()
    this.element.requestSubmit()
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

    this.yesButtonTarget.focus()
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
