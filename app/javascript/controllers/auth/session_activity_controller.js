import { Controller } from "@hotwired/stimulus"
import { railsRequest } from "../../services/rails_request"

const minute = 60_000

// Only genuine interaction renews idle time; background checks only read its deadline.
export default class extends Controller {
  static targets = ["notice", "message", "status", "renew"]
  static values = { url: String, signOutUrl: String, state: Object, messages: Object }

  connect() {
    this.lastAttemptAt = Date.now()
    this.setDeadlines(this.stateValue)
    this.checkStatus()
    this.timer = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.timer)
    document.querySelectorAll("[data-session-activity-expired-notice]").forEach(notice => notice.remove())
  }

  recordInteraction(event) {
    if (!event.isTrusted || document.hidden || this.ended || Date.now() - this.lastAttemptAt < minute) return

    this.renew()
  }

  async renew() {
    if (this.renewing || this.ended) return

    this.renewing = true
    this.lastAttemptAt = Date.now()
    this.renewTarget.disabled = true
    try {
      const { data } = await railsRequest.perform({ method: "post", url: this.urlValue, headers: { Accept: "application/json" } })
      if (!this.setDeadlines(data, this.lastAttemptAt)) throw new Error("Session deadlines unavailable")

      this.refreshFailed = false
      this.warningChecked = false
    } catch (error) {
      if (error.status === 401) this.ended = true
      else this.refreshFailed = true
    } finally {
      this.renewing = false
      this.renewTarget.disabled = false
      this.updateNotice()
    }
  }

  async checkStatus() {
    if (document.hidden || this.checking || this.ended || Date.now() - (this.lastStatusCheckAt || 0) < minute) return

    this.checking = true
    this.lastStatusCheckAt = Date.now()
    try {
      const { data } = await railsRequest.perform({ method: "get", url: this.urlValue, headers: { Accept: "application/json" } })
      if (!this.setDeadlines(data, this.lastStatusCheckAt)) throw new Error("Session deadlines unavailable")

      this.refreshFailed = false
    } catch (error) {
      if (error.status === 401) this.ended = true
      else this.refreshFailed = true
    } finally {
      this.checking = false
      this.updateNotice()
    }
  }

  tick() {
    if (!this.warningChecked && Math.min(this.idleDeadline, this.absoluteDeadline) - Date.now() <= 5 * minute) {
      this.warningChecked = true
      this.checkStatus()
    }
    this.updateNotice()
  }

  setDeadlines(state, observedAt = Date.now()) {
    const issuedAt = Date.parse(state?.issued_at)
    const idle = Date.parse(state?.idle_expires_at)
    const absolute = Date.parse(state?.absolute_expires_at)
    if (![issuedAt, idle, absolute].every(Number.isFinite)) return false
    if (issuedAt < (this.latestIssuedAt || 0)) return true

    // Use server durations so a user's clock setting does not move the deadline.
    this.latestIssuedAt = issuedAt
    this.idleDeadline = observedAt + idle - issuedAt
    this.absoluteDeadline = observedAt + absolute - issuedAt
    this.updateNotice()
    return true
  }

  updateNotice() {
    const idleRemaining = this.idleDeadline - Date.now()
    const absoluteRemaining = this.absoluteDeadline - Date.now()
    const expired = this.ended || Math.min(idleRemaining, absoluteRemaining) <= 0
    let text = ""
    if (expired) {
      text = this.messagesValue.expired
    } else if (absoluteRemaining <= 5 * minute) {
      text = this.messagesValue.absolute
    } else if (this.refreshFailed) {
      text = this.messagesValue.refresh_failed
    } else if (idleRemaining <= 5 * minute) {
      const minutes = Math.max(1, Math.ceil(idleRemaining / minute))
      const template = minutes === 1 ? this.messagesValue.idle_one : this.messagesValue.idle_other
      text = template.replace("%{minutes}", minutes)
    }
    if (this.messageTarget.textContent !== text) this.messageTarget.textContent = text
    if (this.statusTarget.textContent !== text) this.statusTarget.textContent = text
    this.noticeTarget.hidden = !text
    this.renewTarget.hidden = expired || absoluteRemaining <= 5 * minute
    document.querySelectorAll("[data-session-activity-expired-notice]").forEach(notice => {
      notice.hidden = !expired
      const message = expired ? text : ""
      if (notice.textContent !== message) notice.textContent = message
    })
  }

  beforeSubmit(event) {
    const form = event.target
    const method = (event.submitter?.getAttribute("formmethod") || form.getAttribute("method") || form.method).toLowerCase()
    if (method === "get" || method === "dialog") return
    const action = new URL(event.submitter?.getAttribute("formaction") || form.action, document.baseURI)
    const signOut = this.hasSignOutUrlValue && new URL(this.signOutUrlValue, document.baseURI)
    if (signOut && method === "post" && action.origin === window.location.origin && action.pathname === signOut.pathname &&
        form.querySelector('input[name="_method"]')?.value.toLowerCase() === "delete") return
    if (!this.ended && Math.min(this.idleDeadline, this.absoluteDeadline) > Date.now()) return

    event.preventDefault()
    event.stopImmediatePropagation()
    this.updateNotice()
    this.expiredNoticeFor(form).focus()
  }

  expiredNoticeFor(form) {
    const dialog = form.closest("dialog[open]")
    if (!dialog) return this.noticeTarget

    let notice = dialog.querySelector("[data-session-activity-expired-notice]")
    if (!notice) {
      // The page banner is inert behind a modal dialog; keep its message inside the top layer.
      notice = this.noticeTarget.cloneNode(false)
      notice.removeAttribute("data-session-activity-target")
      notice.setAttribute("data-session-activity-expired-notice", "")
      notice.setAttribute("role", "alert")
      notice.lang = this.element.lang
      dialog.prepend(notice)
    }
    if (notice.textContent !== this.messageTarget.textContent) notice.textContent = this.messageTarget.textContent
    notice.hidden = false
    return notice
  }
}
