import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["addressFields", "notice", "emailInput", "emailRadio", "letterRadio"]
  
  connect() {
    this.initializeAddressFields()
  }

  togglePreference(event) {
    const isLetter = event.target.value === "letter"
    this.toggleAddressFields(isLetter)
  }

  toggleAddressFields(show) {
    const inputs = this.addressFieldsTarget.querySelectorAll("input, select")
    const requiredAddressFields = ["user_physical_address_1", "user_city", "user_state", "user_zip_code"]

    setVisible(this.addressFieldsTarget, show, { ariaHidden: !show })
    setVisible(this.noticeTarget, show, { ariaHidden: !show })

    inputs.forEach((el) => {
      el.disabled = !show
      if (requiredAddressFields.includes(el.id)) {
        el.setAttribute("aria-required", show ? "true" : "false")
        setVisible(el, show, { required: show })
      } else {
        el.setAttribute("aria-required", "false")
        setVisible(el, show, { required: false })
      }
    })

    this.emailInputTarget.setAttribute("aria-required", show ? "false" : "true")
    setVisible(this.emailInputTarget, show, { required: !show })
  }

  initializeAddressFields() {
    const isLetterSelected = this.letterRadioTarget.checked
    this.toggleAddressFields(isLetterSelected)
  }
}
