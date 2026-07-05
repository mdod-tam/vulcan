import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["phoneInput", "phoneTypeFields"]

  connect() {
    this.element.dataset.optionalPhoneTypeConnected = "true"
    if (!this.hasPhoneInputTarget || !this.hasPhoneTypeFieldsTarget) return

    this.boundToggle = this.toggle.bind(this)
    this.phoneInputTarget.addEventListener("input", this.boundToggle)
    this.phoneInputTarget.addEventListener("change", this.boundToggle)
    this.phoneInputTarget.addEventListener("blur", this.boundToggle)
    this.phoneInputTarget.addEventListener("keyup", this.boundToggle)

    this.toggle()
  }

  disconnect() {
    if (!this.hasPhoneInputTarget || !this.boundToggle) return

    this.phoneInputTarget.removeEventListener("input", this.boundToggle)
    this.phoneInputTarget.removeEventListener("change", this.boundToggle)
    this.phoneInputTarget.removeEventListener("blur", this.boundToggle)
    this.phoneInputTarget.removeEventListener("keyup", this.boundToggle)
  }

  toggle() {
    const hasPhone = this.phoneInputTarget.value.trim().length > 0
    setVisible(this.phoneTypeFieldsTarget, hasPhone, {
      ariaHidden: !hasPhone,
      inlineStyleFallback: false
    })

    const radios = this.phoneTypeFieldsTarget.querySelectorAll('input[type="radio"]')
    radios.forEach((input) => {
      input.disabled = !hasPhone
      input.required = hasPhone
      input.setAttribute("aria-required", hasPhone.toString())
    })

    if (!hasPhone) {
      radios.forEach((input) => {
        input.checked = false
      })
    }
  }
}
