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
        <input type="checkbox" id="release" name="application[disability_information_release_authorized]" required aria-describedby="disability_release_hint">
        <label for="release"><span>I authorize the release and sharing of my disability-related information.</span></label>
        <p id="disability_release_hint">The program may contact this provider to verify my disability certification.</p>
      </fieldset>
      <fieldset>
        <legend>Income proof</legend>
        <label>Accept <input type="radio" name="income_proof_action" value="accept" required></label>
        <label>Reject <input type="radio" name="income_proof_action" value="reject" required></label>
      </fieldset>
      <label>Provider Name <input type="text" name="application[certifying_professional_name]" required></label>
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
  })

  test("finds blocking required controls, radio groups, and checkbox groups", () => {
    const form = buildForm()

    expect(blockingRequiredControls(form, alwaysVisible).map((field) => field.name))
      .toEqual(["application[disability_information_release_authorized]", "application[certifying_professional_name]"])
    expect(blockingRadioGroups(form, alwaysVisible)).toHaveLength(1)
    expect(blockingCheckboxGroups(form, alwaysVisible)).toHaveLength(1)

    form.querySelector('input[name="income_proof_action"][value="accept"]').checked = true
    form.querySelector('input[name="constituent[hearing_disability]"]').checked = true

    expect(blockingRadioGroups(form, alwaysVisible)).toHaveLength(0)
    expect(blockingCheckboxGroups(form, alwaysVisible)).toHaveLength(0)
  })

  test("a standalone requirement is named by its own label, not its enclosing fieldset legend", () => {
    const release = buildForm().querySelector('input[name="application[disability_information_release_authorized]"]')

    // Helper text linked through aria-describedby stays out of the accessible name, so the
    // status line carries the exact outstanding item without the explanation sentence.
    expect(controlLabel(release)).toBe("I authorize the release and sharing of my disability-related information.")
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
      "I authorize the release and sharing of my disability-related information.",
      "Provider Name",
      "Income proof",
      "Disability type"
    ])
  })

  test("formatIncompleteMessage keeps the base message without a template or labels", () => {
    const base = "Complete all required confirmations before submitting."

    expect(formatIncompleteMessage(base, null, ["Provider Name"])).toBe(base)
    expect(formatIncompleteMessage(base, "Still needed: %{items}.", [])).toBe(base)
    expect(formatIncompleteMessage(base, "Still needed: %{items}.", ["Provider Name", "Income proof"]))
      .toBe("Complete all required confirmations before submitting. Still needed: Provider Name, Income proof.")
    // A label ending in a period is a sentence in the form but a list item here, so the
    // template's period is the only one rendered.
    expect(formatIncompleteMessage(base, "Still needed: %{items}.", ["I authorize the release and sharing of my disability-related information."]))
      .toBe("Complete all required confirmations before submitting. Still needed: I authorize the release and sharing of my disability-related information.")
  })
})
