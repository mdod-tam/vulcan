import { Application } from "@hotwired/stimulus"
import IncomeValidationController from "controllers/forms/income_validation_controller"

describe("IncomeValidationController", () => {
  let application

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  async function validatedDetail(attributes, { householdSize, income }) {
    document.body.innerHTML = `
      <form data-controller="income-validation" ${attributes}>
        <input id="size" type="number" value="${householdSize}" data-income-validation-target="householdSize">
        <input id="income" type="number" value="${income}" data-income-validation-target="annualIncome">
        <div data-income-validation-target="warningContainer" hidden></div>
      </form>
    `
    application = Application.start()
    application.register("income-validation", IncomeValidationController)
    await new Promise(resolve => setTimeout(resolve, 0))

    const events = []
    document.addEventListener("income-validation:validated", event => events.push(event.detail))
    document.querySelector("#income").dispatchEvent(new Event("input", { bubbles: true }))
    return events.at(-1)
  }

  test("uses the server policy's thresholds and modifier", async () => {
    const detail = await validatedDetail(
      `data-income-validation-fpl-thresholds-value='{"1":10000,"2":20000}' data-income-validation-modifier-value="200"`,
      { householdSize: 2, income: 40001 }
    )

    expect(detail).toEqual({ exceedsThreshold: true, income: 40001, threshold: 40000, householdSize: 2 })
  })

  test.each([
    ["an explicit empty policy", `data-income-validation-fpl-thresholds-value="{}" data-income-validation-modifier-value="400"`],
    ["an absent policy attribute", `data-income-validation-modifier-value="400"`]
  ])("falls back to the built-in table for %s", async (_name, attributes) => {
    const detail = await validatedDetail(attributes, { householdSize: 1, income: 62600 })

    expect(detail).toEqual({ exceedsThreshold: false, income: 62600, threshold: 62600, householdSize: 1 })
  })

  test("does not directly enable or disable final submit buttons", () => {
    document.body.innerHTML = `
      <form>
        <button type="submit" disabled>Submit Application</button>
        <div data-income-validation-target="warningContainer"></div>
        <div data-income-validation-target="incomeFieldsContainer"></div>
      </form>
    `

    const button = document.querySelector("button")
    const controller = new IncomeValidationController()

    Object.defineProperty(controller, "hasWarningContainerTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "warningContainerTarget", {
      value: document.querySelector("[data-income-validation-target='warningContainer']"),
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "hasIncomeFieldsContainerTarget", {
      value: true,
      writable: false,
      configurable: true
    })
    Object.defineProperty(controller, "incomeFieldsContainerTarget", {
      value: document.querySelector("[data-income-validation-target='incomeFieldsContainer']"),
      writable: false,
      configurable: true
    })

    controller.updateValidationUI(false, 1000)
    expect(button.disabled).toBe(true)

    controller.updateValidationUI(true, 1000)
    expect(button.disabled).toBe(true)
  })
})
