import { Application } from "@hotwired/stimulus"
import IncomeValidationController from "controllers/forms/income_validation_controller"
import FinalSubmitGateController from "controllers/forms/final_submit_gate_controller"

const messages = {
  title: "Income is above the limit",
  limit: "The income limit is %{threshold} per year.",
  ineligible: "Households above this limit are not eligible.",
  unavailable: "We couldn't check the income limit. Please try again later."
}

describe("IncomeValidationController", () => {
  let application
  let controller
  let form
  let events

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ""
  })

  async function mount({ householdSize = 1, income = 0, thresholds = { 1: 15650, 8: 54150 },
                         modifier = 400, additionalPerson = 5500, locale = "en", warningMessages = messages,
                         portal = false, dispatchInput = true, fieldsContainer = !portal } = {}) {
    document.body.innerHTML = `
      <form data-controller="income-validation${portal ? ' final-submit-gate' : ''}">
        <input id="size" type="number" min="1" value="${householdSize}" data-income-validation-target="householdSize">
        <input id="income" type="number" min="0" step="0.01" required value="${income}" data-income-validation-target="annualIncome">
        <div data-income-validation-target="warningContainer" hidden></div>
        ${fieldsContainer ? '<div data-income-validation-target="incomeFieldsContainer"></div>' : ''}
        <button type="submit" disabled ${portal ? 'data-final-submit-gate-target="submitButton"' : ''}>Submit Application</button>
      </form>
    `
    form = document.querySelector("form")
    form.setAttribute("data-income-validation-fpl-thresholds-value", JSON.stringify(thresholds))
    form.setAttribute("data-income-validation-modifier-value", modifier)
    form.setAttribute("data-income-validation-additional-person-value", additionalPerson)
    form.setAttribute("data-income-validation-messages-value", JSON.stringify(warningMessages))
    form.setAttribute("data-income-validation-locale-value", locale)
    events = []
    form.addEventListener("income-validation:validated", event => events.push(event.detail))
    application = Application.start()
    application.register("income-validation", IncomeValidationController)
    application.register("final-submit-gate", FinalSubmitGateController)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(form, "income-validation")
    if (dispatchInput) document.querySelector("#income").dispatchEvent(new Event("input", { bubbles: true }))
    return events.at(-1)
  }

  test("restored portal income blocks the connected submit gate until corrected", async () => {
    const detail = await mount({ portal: true, dispatchInput: false, householdSize: 2, income: 50000.25, thresholds: { 2: 10000 } })
    expect(detail).toEqual({ exceedsThreshold: true, income: 50000.25, threshold: 40000, householdSize: 2 })
    const warning = form.querySelector('[data-income-validation-target="warningContainer"]')
    expect(warning.hidden).toBe(false)
    expect(form.querySelector('button').disabled).toBe(true)

    const income = form.querySelector('#income')
    income.value = '0'
    income.dispatchEvent(new Event('input', { bubbles: true }))
    expect(warning.hidden).toBe(true)
    expect(form.querySelector('button').disabled).toBe(false)
  })

  test("uses the server policy's thresholds and modifier", async () => {
    const detail = await mount({ thresholds: { 2: 20000 }, modifier: 200, householdSize: 2, income: 40001 })
    expect(detail).toEqual({ exceedsThreshold: true, income: 40001, threshold: 40000, householdSize: 2 })
  })

  test.each([[8, 216600], [9, 238600], [10, 260600]])("extends the configured FPL table for household size %s", async (householdSize, threshold) => {
    const detail = await mount({ householdSize, income: threshold + 0.01 })
    expect(detail).toEqual({ exceedsThreshold: true, income: threshold + 0.01, threshold, householdSize })
  })

  test.each([0, 0.01])("validates income %s without treating it as missing", async income => {
    const detail = await mount({ income })
    expect(detail).toEqual({ exceedsThreshold: false, income, threshold: 62600, householdSize: 1 })
    expect(document.querySelector("#income").validationMessage).toBe("")
  })

  test("missing policy data shows an error and never guesses a threshold", async () => {
    const detail = await mount({ thresholds: {}, income: 100 })
    expect(detail.unavailable).toBe(true)
    expect(document.querySelector("#income").validationMessage).toBe(messages.unavailable)
    expect(form.textContent).toContain(messages.unavailable)
    expect(form.textContent).not.toContain(messages.ineligible)

    controller.fplThresholdsValue = { 1: 15650 }
    controller.validateIncomeThreshold()
    expect(document.querySelector("#income").validationMessage).toBe("")
    expect(events.at(-1).threshold).toBe(62600)
  })

  test("missing additional-person policy blocks only larger households and clears after size correction", async () => {
    const detail = await mount({ portal: true, fieldsContainer: true, additionalPerson: null, householdSize: 1, income: 100 })
    const submitGate = application.getControllerForElementAndIdentifier(form, "final-submit-gate")
    submitGate.elementIsVisible = () => true
    expect(detail).toEqual({ exceedsThreshold: false, income: 100, threshold: 62600, householdSize: 1 })
    expect(form.querySelector('button').disabled).toBe(false)

    const household = form.querySelector('#size')
    household.value = '9'
    household.dispatchEvent(new Event('input', { bubbles: true }))
    expect(events.at(-1).unavailable).toBe(true)
    expect(form.querySelector('#income').validationMessage).toBe(messages.unavailable)
    expect(form.querySelector('button').disabled).toBe(true)
    expect(form.querySelector('[data-income-validation-target="incomeFieldsContainer"]').classList.contains('bg-success-50')).toBe(false)
    expect(form.querySelector('[data-income-validation-target="incomeFieldsContainer"]').classList.contains('bg-gray-50')).toBe(true)

    household.value = '8'
    household.dispatchEvent(new Event('input', { bubbles: true }))
    expect(events.at(-1)).toEqual({ exceedsThreshold: false, income: 100, threshold: 216600, householdSize: 8 })
    expect(form.querySelector('#income').validationMessage).toBe('')
    expect(form.querySelector('button').disabled).toBe(false)
  })

  test("Spanish warning text comes from the selected form locale", async () => {
    await mount({ income: 62600.01, locale: "es", warningMessages: {
      title: "Los ingresos superan el límite",
      limit: "El límite de ingresos es %{threshold} al año.",
      ineligible: "Los hogares por encima del límite no son elegibles.",
      unavailable: "No pudimos comprobar el límite de ingresos."
    } })
    const warning = form.querySelector('[data-income-validation-target="warningContainer"]')
    expect(warning.textContent).toContain("Los ingresos superan el límite")
    expect(warning.textContent).toContain("El límite de ingresos es")
    expect(warning.textContent).not.toContain(messages.title)
  })

  test("a restored benefit-proof choice clears the hidden numeric warning and keeps it clear", async () => {
    await mount({ income: 999999 })
    const action = document.createElement("input")
    action.type = "radio"
    action.name = "income_proof_action"
    action.value = "accept"
    action.checked = true
    const benefits = document.createElement("input")
    benefits.type = "checkbox"
    benefits.checked = true
    benefits.setAttribute("data-income-validation-target", "noIncomeProvided")
    form.append(action, benefits)
    await new Promise(resolve => setTimeout(resolve, 0))
    controller.toggleIncomeRequirement()
    controller.validateIncomeThreshold()
    expect(events.at(-1).exceedsThreshold).toBe(false)
    expect(document.querySelector("#income").required).toBe(false)
    expect(form.querySelector('[data-income-validation-target="warningContainer"]').hidden).toBe(true)
    benefits.checked = false
    controller.toggleIncomeRequirement()
    expect(events.at(-1).exceedsThreshold).toBe(true)
    expect(document.querySelector("#income").required).toBe(true)
  })

  test("does not directly enable or disable final submit buttons", async () => {
    await mount()
    const button = form.querySelector("button")
    controller.updateValidationUI(false, 1000)
    expect(button.disabled).toBe(true)
    controller.updateValidationUI(true, 1000)
    expect(button.disabled).toBe(true)
  })
})
