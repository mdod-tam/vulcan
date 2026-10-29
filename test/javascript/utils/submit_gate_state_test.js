import {
  blockingCheckboxGroups,
  blockingRadioGroups,
  blockingRequiredControls,
  controlLabel,
  elementIsVisible,
  formatIncompleteMessage,
  groupLabel,
  incompleteGroupLabels
} from "utils/submit_gate_state"

function buildForm() {
  document.body.innerHTML = `
    <form>
      <fieldset data-requires-one-checkbox="true">
        <legend>Disability type</legend>
        <label><input type="checkbox" name="constituent[hearing_disability]"> Hearing</label>
        <label><input type="checkbox" name="constituent[vision_disability]"> Vision</label>
      </fieldset>
      <fieldset>
        <legend>Certifying Professional Information</legend>
        <input type="checkbox" id="release" name="application[medical_release_authorized]" required>
        <label for="release">
          <span>I authorize medical release</span>
          <span>I authorize the program to contact this provider to verify my disability certification</span>
        </label>
      </fieldset>
      <fieldset>
        <legend>Income proof</legend>
        <label>Accept <input type="radio" name="income_proof_action" value="accept" required></label>
        <label>Reject <input type="radio" name="income_proof_action" value="reject" required></label>
      </fieldset>
      <label>Provider name <input type="text" name="application[medical_provider_name]" required></label>
    </form>
  `
  return document.querySelector("form")
}

const alwaysVisible = () => true

afterEach(() => {
  document.body.innerHTML = ""
})

describe("submit_gate_state", () => {
  test("treats an element as visible only when it has layout", () => {
    const form = buildForm()
    // jsdom performs no layout, so rendered elements report no boxes.
    expect(elementIsVisible(form.querySelector("label"))).toBe(false)
    expect(alwaysVisible(form.querySelector("label"))).toBe(true)
  })

  test("finds blocking required controls, radio groups, and checkbox groups", () => {
    const form = buildForm()

    expect(blockingRequiredControls(form, alwaysVisible).map((field) => field.name))
      .toEqual(["application[medical_release_authorized]", "application[medical_provider_name]"])
    expect(blockingRadioGroups(form, alwaysVisible)).toHaveLength(1)
    expect(blockingCheckboxGroups(form, alwaysVisible)).toHaveLength(1)

    form.querySelector('input[name="income_proof_action"][value="accept"]').checked = true
    form.querySelector('input[name="constituent[hearing_disability]"]').checked = true

    expect(blockingRadioGroups(form, alwaysVisible)).toHaveLength(0)
    expect(blockingCheckboxGroups(form, alwaysVisible)).toHaveLength(0)
  })

  test("a standalone requirement is named by its own label, not its enclosing fieldset legend", () => {
    const release = buildForm().querySelector('input[name="application[medical_release_authorized]"]')

    expect(controlLabel(release)).toBe(
      "I authorize medical release I authorize the program to contact this provider to verify my disability certification"
    )
  })

  test("grouped decisions are named by their legend, and unlabeled controls fall back to aria-label then name", () => {
    const form = buildForm()
    const radio = form.querySelector('input[name="income_proof_action"]')
    const group = form.querySelector("[data-requires-one-checkbox]")

    expect(groupLabel(radio)).toBe("Income proof")
    expect(groupLabel(group)).toBe("Disability type")

    const unlabeled = document.createElement("input")
    unlabeled.required = true
    unlabeled.name = "application[annual_income]"
    expect(controlLabel(unlabeled)).toBe("application[annual_income]")

    unlabeled.setAttribute("aria-label", "Annual income")
    expect(controlLabel(unlabeled)).toBe("Annual income")
  })

  test("incompleteGroupLabels names every blocker once, in form order", () => {
    const form = buildForm()

    expect(incompleteGroupLabels(form, alwaysVisible)).toEqual([
      "I authorize medical release I authorize the program to contact this provider to verify my disability certification",
      "Provider name",
      "Income proof",
      "Disability type"
    ])
  })

  test("formatIncompleteMessage keeps the base message without a template or labels", () => {
    const base = "Complete all required confirmations before submitting."

    expect(formatIncompleteMessage(base, null, ["Provider name"])).toBe(base)
    expect(formatIncompleteMessage(base, "Still needed: %{items}.", [])).toBe(base)
    expect(formatIncompleteMessage(base, "Still needed: %{items}.", ["Provider name", "Income proof"]))
      .toBe("Complete all required confirmations before submitting. Still needed: Provider name, Income proof.")
  })
})
