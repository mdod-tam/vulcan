import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["phoneInput", "phoneTypeFields"]

  connect() {
    this.toggle()
  }

  toggle() {
    const hasPhone = this.phoneInputTarget.value.trim().length > 0
    setVisible(this.phoneTypeFieldsTarget, hasPhone, { ariaHidden: !hasPhone })

    this.phoneTypeFieldsTarget.querySelectorAll("input").forEach((input) => {
      input.disabled = !hasPhone
    })
  }
}
