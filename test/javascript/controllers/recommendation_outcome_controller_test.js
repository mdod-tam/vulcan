import { Application } from "@hotwired/stimulus"
import RecommendationOutcomeController from "controllers/evaluators/recommendation_outcome_controller"

describe("RecommendationOutcomeController", () => {
  let application
  let form
  let notes

  async function restore(outcome, source) {
    document.body.innerHTML = `
      <form data-controller="recommendation-outcome">
        ${source ? `
          <select data-recommendation-outcome-target="source" data-action="recommendation-outcome#update">
            <option value="direct_assessment" ${source === "direct_assessment" ? "selected" : ""}>Direct assessment</option>
            <option value="outside_specialist" ${source === "outside_specialist" ? "selected" : ""}>Outside specialist</option>
          </select>
          <input name="evaluation[location]" value="Restored location" data-recommendation-outcome-target="location">
          <span data-recommendation-outcome-target="locationRequired">Required location</span>
        ` : ""}
        <fieldset>
          ${["catalog_products", "outside_catalog", "no_suitable_product"].map(value => `
            <input type="radio" name="evaluation[recommendation_outcome]" value="${value}"
                   ${value === outcome ? "checked" : ""} required
                   data-recommendation-outcome-target="choice"
                   data-recommendation-outcome-feedback="Feedback for ${value}"
                   data-action="recommendation-outcome#update">
          `).join("")}
        </fieldset>
        <span data-recommendation-outcome-target="triedRequired">Required tried products</span>
        <input type="hidden" name="evaluation[products_tried_field][]" value="">
        <input type="checkbox" name="evaluation[products_tried_field][]" value="12" checked>
        <fieldset data-recommendation-outcome-target="catalog" ${outcome === "catalog_products" ? "" : "hidden disabled"}>
          <input type="hidden" name="evaluation[recommended_product_ids][]" value="">
          <input type="checkbox" name="evaluation[recommended_product_ids][]" value="31" checked>
        </fieldset>
        <span data-recommendation-outcome-target="notesRequired">Required details</span>
        <textarea name="evaluation[recommendation_notes]" data-recommendation-outcome-target="notes">Restored details</textarea>
        <p role="status" aria-live="polite" data-recommendation-outcome-target="status"></p>
      </form>
    `
    application = Application.start()
    application.register("recommendation-outcome", RecommendationOutcomeController)
    form = document.querySelector("form")
    notes = form.querySelector("textarea")
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  test("a new report remains unselected and invalid until the evaluator chooses an outcome", async () => {
    await restore(null)

    expect(form.querySelector('input[type="radio"]:checked')).toBeNull()
    expect(form.checkValidity()).toBe(false)
    expect(new FormData(form).has("evaluation[recommended_product_ids][]")).toBe(false)
    expect(notes.required).toBe(false)

    form.querySelector('input[value="catalog_products"]').click()

    expect(form.checkValidity()).toBe(true)
    expect(new FormData(form).getAll("evaluation[recommended_product_ids][]")).toEqual(["", "31"])
    expect(form.querySelector('[role="status"]')).toHaveTextContent("Feedback for catalog_products")
  })

  test("a restored external outcome omits catalog selections without losing tried products or details", async () => {
    await restore("outside_catalog")
    const data = new FormData(form)

    expect(data.has("evaluation[recommended_product_ids][]")).toBe(false)
    expect(data.getAll("evaluation[products_tried_field][]")).toEqual(["", "12"])
    expect(data.get("evaluation[recommendation_notes]")).toBe("Restored details")
    expect(notes.required).toBe(true)
    expect(notes.getAttribute("aria-required")).toBe("true")
    expect(form.querySelector('[data-recommendation-outcome-target="triedRequired"]')).toHaveClass("hidden")
    expect(form.querySelector('[data-recommendation-outcome-target="catalog"]').hidden).toBe(true)
    expect(form.querySelector('[data-recommendation-outcome-target="catalog"]').disabled).toBe(true)
    expect(form.querySelector('[role="status"]')).toHaveTextContent("")
  })

  test("switching a restored external outcome to catalog restores submitted selections and optional details", async () => {
    await restore("outside_catalog")
    form.querySelector('input[value="catalog_products"]').click()
    const data = new FormData(form)

    expect(data.getAll("evaluation[recommended_product_ids][]")).toEqual(["", "31"])
    expect(data.get("evaluation[recommendation_notes]")).toBe("Restored details")
    expect(notes.required).toBe(false)
    expect(notes.getAttribute("aria-required")).toBe("false")
    expect(form.querySelector('[data-recommendation-outcome-target="catalog"]')).not.toHaveClass("hidden")
    expect(form.querySelector('[data-recommendation-outcome-target="triedRequired"]')).not.toHaveClass("hidden")
    expect(form.querySelector('[data-recommendation-outcome-target="catalog"]').hidden).toBe(false)
    expect(form.querySelector('[data-recommendation-outcome-target="catalog"]').disabled).toBe(false)
    expect(form.querySelector('[role="status"]')).toHaveTextContent("Feedback for catalog_products")
  })

  test("no suitable product allows zero tried products while requiring the reason", async () => {
    await restore("catalog_products")
    form.querySelector('input[name="evaluation[products_tried_field][]"][type="checkbox"]').checked = false
    form.querySelector('input[value="no_suitable_product"]').click()
    notes.value = ""

    expect(new FormData(form).getAll("evaluation[products_tried_field][]")).toEqual([""])
    expect(new FormData(form).has("evaluation[recommended_product_ids][]")).toBe(false)
    expect(notes.required).toBe(true)
    expect(form.querySelector('[role="status"]')).toHaveTextContent("Feedback for no_suitable_product")
    expect(form.checkValidity()).toBe(false)
    notes.value = "No suitable equipment; arrange a specialist assessment."
    expect(form.checkValidity()).toBe(true)
  })

  test("changing outcome preserves edits and clearing optional catalog details remains possible", async () => {
    await restore("outside_catalog")
    notes.value = "Edited recommendation"
    form.querySelector('input[value="no_suitable_product"]').click()
    expect(notes.value).toBe("Edited recommendation")

    form.querySelector('input[value="catalog_products"]').click()
    notes.value = ""
    expect(new FormData(form).get("evaluation[recommendation_notes]")).toBe("")
    expect(form.checkValidity()).toBe(true)
  })

  test("restored outside consultation keeps catalog recommendations while location and trials stay optional", async () => {
    await restore("catalog_products", "outside_specialist")
    const location = form.querySelector('[name="evaluation[location]"]')
    const source = form.querySelector("select")

    expect(location.required).toBe(false)
    expect(location.getAttribute("aria-required")).toBe("false")
    expect(form.querySelector('[data-recommendation-outcome-target="triedRequired"]')).toHaveClass("hidden")
    expect(new FormData(form).getAll("evaluation[recommended_product_ids][]")).toEqual(["", "31"])

    source.value = "direct_assessment"
    source.dispatchEvent(new Event("change", { bubbles: true }))
    expect(location.required).toBe(true)
    expect(location.getAttribute("aria-required")).toBe("true")
    expect(location.value).toBe("Restored location")
    expect(form.querySelector('[data-recommendation-outcome-target="locationRequired"]')).not.toHaveClass("hidden")
    expect(form.querySelector('[data-recommendation-outcome-target="triedRequired"]')).not.toHaveClass("hidden")

    source.value = "outside_specialist"
    source.dispatchEvent(new Event("change", { bubbles: true }))
    location.value = ""
    expect(location.required).toBe(false)
    expect(new FormData(form).get("evaluation[location]")).toBe("")
    expect(form.checkValidity()).toBe(true)
  })
})
