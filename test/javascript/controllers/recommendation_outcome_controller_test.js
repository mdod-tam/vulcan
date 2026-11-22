import { Application } from "@hotwired/stimulus"
import RecommendationOutcomeController from "controllers/evaluators/recommendation_outcome_controller"

describe("RecommendationOutcomeController", () => {
  let application
  let form

  async function restore({ catalog = false, noSuitable = false, tried = false, reaction = "", source = "direct_assessment" } = {}) {
    document.body.innerHTML = `
      <form data-controller="recommendation-outcome" data-action="change->recommendation-outcome#update"
            data-recommendation-outcome-conflict-value="Clear catalog selections first.">
        <select data-recommendation-outcome-target="source">
          <option value="direct_assessment" ${source === "direct_assessment" ? "selected" : ""}>Direct assessment</option>
          <option value="outside_specialist" ${source === "outside_specialist" ? "selected" : ""}>Outside specialist</option>
        </select>
        <input name="evaluation[location]" value="Restored location" data-recommendation-outcome-target="location">
        <span data-recommendation-outcome-target="locationRequired">Required location</span>
        <span data-recommendation-outcome-target="triedRequired">Required trial</span>
        <div data-recommendation-outcome-target="trialRow">
          <input id="tried" type="checkbox" name="evaluation[products_tried_inputs][12][selected]" value="1" ${tried ? "checked" : ""} data-trial-choice>
          <div data-trial-rating>
            <select name="evaluation[products_tried_inputs][12][reaction]" data-trial-reaction>
              <option value="">Select satisfaction</option>
              ${["Satisfied", "Neutral", "Dissatisfied"].map(value => `<option ${value === reaction ? "selected" : ""}>${value}</option>`).join("")}
            </select>
          </div>
        </div>
        <input id="catalog" type="checkbox" name="evaluation[recommended_product_ids][]" value="31" ${catalog ? "checked" : ""} data-recommendation-outcome-target="catalog">
        <span data-recommendation-outcome-target="notesRequired">Required details</span>
        <textarea name="evaluation[recommendation_notes]" data-recommendation-outcome-target="notes">Restored non-catalog details</textarea>
        <input id="none" type="checkbox" name="evaluation[no_suitable_product]" value="1" ${noSuitable ? "checked" : ""} data-recommendation-outcome-target="noSuitable">
      </form>
    `
    application = Application.start()
    application.register("recommendation-outcome", RecommendationOutcomeController)
    form = document.querySelector("form")
    await new Promise(resolve => setTimeout(resolve, 0))
  }

  function change(element, value) {
    if (element.type === "checkbox") element.checked = value
    else element.value = value
    element.dispatchEvent(new Event("change", { bubbles: true }))
  }

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  test("catalog and non-catalog recommendations remain enabled together through selection and clearing", async () => {
    await restore()
    const notes = form.querySelector("textarea")
    const catalog = form.querySelector("#catalog")
    expect(notes.required).toBe(true)
    expect(catalog.disabled).toBe(false)
    change(catalog, true)
    expect(notes.required).toBe(false)
    expect(notes.getAttribute("aria-required")).toBe("false")
    expect(new FormData(form).get("evaluation[recommendation_notes]")).toBe("Restored non-catalog details")
    expect(new FormData(form).getAll("evaluation[recommended_product_ids][]")).toEqual(["31"])
    change(catalog, false)
    expect(notes.required).toBe(true)
    expect(notes.value).toBe("Restored non-catalog details")
  })

  test("no-suitable conflicts are visible to native validation without silently clearing selections", async () => {
    await restore({ catalog: true })
    change(form.querySelector("#none"), true)
    expect(form.checkValidity()).toBe(false)
    expect(form.querySelector("#none").validationMessage).toBe("Clear catalog selections first.")
    expect(form.querySelector("#catalog").checked).toBe(true)
    expect(form.querySelector("textarea").required).toBe(true)
    change(form.querySelector("#catalog"), false)
    expect(form.checkValidity()).toBe(true)
    change(form.querySelector("#none"), false)
    expect(form.querySelector("textarea").value).toBe("Restored non-catalog details")
  })

  test("only tried products require a rating and toggling a product retains its draft rating", async () => {
    await restore()
    const tried = form.querySelector("#tried")
    const rating = form.querySelector("[data-trial-reaction]")
    expect(rating.disabled).toBe(true)
    expect(rating.parentElement.hidden).toBe(true)
    change(tried, true)
    expect(rating.disabled).toBe(false)
    expect(rating.parentElement.hidden).toBe(false)
    expect(rating.required).toBe(true)
    expect(rating.getAttribute("aria-required")).toBe("true")
    expect(form.checkValidity()).toBe(false)
    change(rating, "Neutral")
    expect(form.checkValidity()).toBe(true)
    change(tried, false)
    expect(new FormData(form).has("evaluation[products_tried_inputs][12][reaction]")).toBe(false)
    change(tried, true)
    expect(rating.value).toBe("Neutral")
    expect(form.checkValidity()).toBe(true)
  })

  test("restored reactions and recommendation selections survive source changes", async () => {
    await restore({ catalog: true, tried: true, reaction: "Dissatisfied", source: "outside_specialist" })
    const source = form.querySelector("select")
    const location = form.querySelector("[name='evaluation[location]']")
    expect(location.required).toBe(false)
    expect(form.querySelector("[data-trial-reaction]").value).toBe("Dissatisfied")
    change(source, "direct_assessment")
    expect(location.required).toBe(true)
    expect(location.getAttribute("aria-required")).toBe("true")
    expect(form.querySelector('[data-recommendation-outcome-target="triedRequired"]')).not.toHaveClass("hidden")
    change(source, "outside_specialist")
    change(location, "")
    expect(location.required).toBe(false)
    expect(form.querySelector("#tried").checked).toBe(true)
    expect(new FormData(form).get("evaluation[products_tried_inputs][12][reaction]")).toBe("Dissatisfied")
  })
  test("catalog discovery follows explicit groups without dropping checked rows", async () => {
    await restore()
    form.insertAdjacentHTML("beforeend", `
      <style>.flex { display: flex; } .hidden { display: none; }</style>
      <input type="checkbox" value="deaf" checked data-recommendation-outcome-target="group">
      <input type="checkbox" value="deafblind" data-recommendation-outcome-target="group">
      <input type="search" data-recommendation-outcome-target="search" data-action="input->recommendation-outcome#filter">
      <input type="checkbox" data-recommendation-outcome-target="showAll">
      <div id="deaf-model" class="flex" data-recommendation-outcome-target="productRow" data-product-groups="deaf" data-product-search="apple phone"><input type="checkbox"></div>
      <div id="braille-model" class="flex" data-recommendation-outcome-target="productRow" data-product-groups="deafblind" data-product-search="braille display"><input type="checkbox"></div>
    `)
    await new Promise(resolve => setTimeout(resolve, 0))
    const controller = application.getControllerForElementAndIdentifier(form, "recommendation-outcome")
    controller.filter()
    expect(form.querySelector("#deaf-model").hidden).toBe(false)
    expect(form.querySelector("#braille-model").hidden).toBe(true)
    expect(form.querySelector("#braille-model")).not.toBeVisible()
    change(form.querySelector('[data-recommendation-outcome-target="showAll"]'), true)
    expect(form.querySelector("#braille-model").hidden).toBe(false)
    expect(form.querySelector("#braille-model")).toBeVisible()
    change(form.querySelector("#braille-model input"), true)
    change(form.querySelector('[data-recommendation-outcome-target="showAll"]'), false)
    expect(form.querySelector("#braille-model").hidden).toBe(false)
    change(form.querySelector("#braille-model input"), false)
    expect(form.querySelector("#braille-model").hidden).toBe(true)
    change(form.querySelector('[data-recommendation-outcome-target="group"][value="deafblind"]'), true)
    expect(form.querySelector("#braille-model").hidden).toBe(false)
  })

})
