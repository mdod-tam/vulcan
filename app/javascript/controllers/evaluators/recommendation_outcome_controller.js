import { Controller } from "@hotwired/stimulus"
import { setVisible } from "../../utils/visibility"

export default class extends Controller {
  static targets = ["catalog", "noSuitable", "notes", "trialRow", "triedRequired", "notesRequired", "source", "location", "locationRequired"]
  static values = { conflict: String }

  connect() {
    this.update()
  }

  update() {
    const catalog = this.catalogTargets.some(input => input.checked)
    const outsideSpecialist = this.hasSourceTarget && this.sourceTarget.value !== "direct_assessment"
    const needsDetails = this.noSuitableTarget.checked || !catalog

    this.noSuitableTarget.setCustomValidity(this.noSuitableTarget.checked && catalog ? this.conflictValue : "")
    this.notesTarget.required = needsDetails
    this.notesTarget.setAttribute("aria-required", String(needsDetails))
    setVisible(this.triedRequiredTarget, catalog && !outsideSpecialist)
    setVisible(this.notesRequiredTarget, needsDetails)

    this.trialRowTargets.forEach(row => {
      const selected = row.querySelector("[data-trial-choice]").checked
      const rating = row.querySelector("[data-trial-reaction]")
      row.querySelector("[data-trial-rating]").hidden = !selected
      rating.disabled = !selected
      rating.required = selected
      rating.setAttribute("aria-required", String(selected))
    })

    if (this.hasLocationTarget) {
      this.locationTarget.required = !outsideSpecialist
      this.locationTarget.setAttribute("aria-required", String(!outsideSpecialist))
      setVisible(this.locationRequiredTarget, !outsideSpecialist)
    }
  }
}
