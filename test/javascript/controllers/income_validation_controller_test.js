import IncomeValidationController from "controllers/forms/income_validation_controller"

describe("IncomeValidationController", () => {
  afterEach(() => {
    document.body.innerHTML = ""
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
