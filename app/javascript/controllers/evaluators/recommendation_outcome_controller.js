import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["choice", "catalog", "notes", "triedRequired", "notesRequired", "status"]

  connect() {
    this.update()
  }

  update(event) {
    const choice = this.choiceTargets.find(choice => choice.checked)
    const selected = choice?.value
    const catalog = selected === "catalog_products"
    const needsDetails = selected === "outside_catalog" || selected === "no_suitable_product"

    setVisible(this.catalogTarget, catalog)
    this.catalogTarget.hidden = !catalog
    this.catalogTarget.disabled = !catalog
    this.catalogTarget.querySelectorAll("input").forEach(input => {
      input.disabled = !catalog
    })

    this.notesTarget.required = needsDetails
    this.notesTarget.setAttribute("aria-required", String(needsDetails))

    setVisible(this.triedRequiredTarget, catalog)
    setVisible(this.notesRequiredTarget, needsDetails)

    if (event) {
      this.statusTarget.textContent = choice?.dataset.recommendationOutcomeFeedback || ""
    }
  }
}
