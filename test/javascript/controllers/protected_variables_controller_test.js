import { Application } from "@hotwired/stimulus"
import ProtectedVariablesController from "../../../app/javascript/controllers/admin/protected_variables_controller"

describe("ProtectedVariablesController", () => {
  let application

  beforeEach(async () => {
    document.body.innerHTML = `
      <div data-controller="protected-variables">
        <select data-protected-variables-target="syntaxSelect">
          <option value="legacy_percent" selected>Standard</option>
          <option value="liquid">Liquid</option>
        </select>
        <p data-protected-variables-target="standardHelp">Standard help</p>
        <div class="hidden" data-protected-variables-target="liquidHelp">Liquid help</div>
        <div class="hidden" data-protected-variables-target="convertPanel">
          <button type="button" data-action="protected-variables#convertStandardPlaceholders">Convert</button>
        </div>
        <input data-protected-variables-target="subjectInput" value="Subject %<name>s">
        <select data-protected-variables-target="subjectVariableSelect">
          <option value="">-- Select a variable to insert --</option>
          <option value="%<name>s"
                  data-variable-name="name"
                  data-variable-kind="required"
                  data-legacy-placeholder="%<name>s"
                  data-liquid-placeholder="{{ name }}"
                  data-legacy-label="Name - %<name>s"
                  data-liquid-label="Name - {{ name }}">Name - %<name>s</option>
          <option value="%<nickname>s"
                  data-variable-name="nickname"
                  data-variable-kind="optional"
                  data-legacy-placeholder="%<nickname>s"
                  data-liquid-placeholder="{{ nickname }}"
                  data-legacy-label="Nickname - %<nickname>s"
                  data-liquid-label="Nickname - {{ nickname }}">Nickname - %<nickname>s</option>
        </select>
        <textarea data-protected-variables-target="textarea">Hello {{- user.first_name -}} and %<name>s</textarea>
        <div data-protected-variables-target="editor"></div>
        <select data-protected-variables-target="variableSelect">
          <option value="">-- Select a variable to insert --</option>
          <option value="%<name>s"
                  data-variable-name="name"
                  data-variable-kind="required"
                  data-legacy-placeholder="%<name>s"
                  data-liquid-placeholder="{{ name }}"
                  data-legacy-label="Name - %<name>s"
                  data-liquid-label="Name - {{ name }}">Name - %<name>s</option>
          <option value="%<nickname>s"
                  data-variable-name="nickname"
                  data-variable-kind="optional"
                  data-legacy-placeholder="%<nickname>s"
                  data-liquid-placeholder="{{ nickname }}"
                  data-legacy-label="Nickname - %<nickname>s"
                  data-liquid-label="Nickname - {{ nickname }}">Nickname - %<nickname>s</option>
        </select>
      </div>
    `

    application = Application.start()
    application.register("protected-variables", ProtectedVariablesController)
    await Promise.resolve()
  })

  afterEach(() => {
    application.stop()
    jest.restoreAllMocks()
    document.body.innerHTML = ""
  })

  test("protects Liquid trim output tags", () => {
    const variables = Array.from(document.querySelectorAll(".protected-variable")).map((node) => node.textContent)

    expect(variables).toContain("{{- user.first_name -}}")
    expect(variables).toContain("%<name>s")
  })

  test("updates variable option values when syntax changes", () => {
    jest.spyOn(window, "confirm").mockReturnValue(true)
    const syntaxSelect = document.querySelector("[data-protected-variables-target='syntaxSelect']")
    const variableOption = document.querySelector("[data-protected-variables-target='variableSelect'] [data-legacy-placeholder='%<name>s']")
    const optionalVariableOption = document.querySelector("[data-protected-variables-target='variableSelect'] [data-legacy-placeholder='%<nickname>s']")
    const subjectVariableOption = document.querySelector("[data-protected-variables-target='subjectVariableSelect'] [data-legacy-placeholder='%<name>s']")
    const optionalSubjectOption = document.querySelector("[data-protected-variables-target='subjectVariableSelect'] [data-legacy-placeholder='%<nickname>s']")

    expect(variableOption.value).toBe("%<name>s")
    expect(subjectVariableOption.value).toBe("%<name>s")
    expect(optionalVariableOption.disabled).toBe(false)
    expect(optionalSubjectOption.disabled).toBe(false)
    expect(variableOption.textContent).toBe("Name - %<name>s")
    expect(document.querySelector("[data-protected-variables-target='standardHelp']").classList).not.toContain("hidden")
    expect(document.querySelector("[data-protected-variables-target='liquidHelp']").classList).toContain("hidden")
    expect(document.querySelector("[data-protected-variables-target='convertPanel']").classList).toContain("hidden")

    syntaxSelect.value = "liquid"
    syntaxSelect.dispatchEvent(new Event("change"))

    expect(variableOption.value).toBe("{{ name }}")
    expect(subjectVariableOption.value).toBe("{{ name }}")
    expect(variableOption.textContent).toBe("Name - {{ name }}")
    expect(optionalVariableOption.value).toBe("%<nickname>s")
    expect(optionalVariableOption.disabled).toBe(true)
    expect(optionalVariableOption.textContent).toBe("Nickname - %<nickname>s (Standard only)")
    expect(optionalSubjectOption.disabled).toBe(true)
    expect(document.querySelector("[data-protected-variables-target='standardHelp']").classList).toContain("hidden")
    expect(document.querySelector("[data-protected-variables-target='liquidHelp']").classList).not.toContain("hidden")
    expect(document.querySelector("[data-protected-variables-target='convertPanel']").classList).not.toContain("hidden")
  })

  test("inserts selected variable into subject at cursor", () => {
    const subjectInput = document.querySelector("[data-protected-variables-target='subjectInput']")
    const subjectSelect = document.querySelector("[data-protected-variables-target='subjectVariableSelect']")
    subjectInput.value = "Hello "
    subjectInput.setSelectionRange(6, 6)

    subjectSelect.value = "%<name>s"
    subjectSelect.dispatchEvent(new Event("change"))

    expect(subjectInput.value).toBe("Hello %<name>s")
    expect(subjectSelect.value).toBe("")
  })

  test("inserts selected variable into body at saved cursor", () => {
    const editor = document.querySelector("[data-protected-variables-target='editor']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")
    const variableSelect = document.querySelector("[data-protected-variables-target='variableSelect']")
    editor.textContent = "Hello friend"
    textarea.value = "Hello friend"

    const range = document.createRange()
    range.setStart(editor.firstChild, 6)
    range.collapse(true)
    window.getSelection().removeAllRanges()
    window.getSelection().addRange(range)

    variableSelect.value = "%<name>s"
    variableSelect.dispatchEvent(new Event("change"))

    expect(textarea.value).toBe("Hello %<name>sfriend")
    expect(variableSelect.value).toBe("")
  })

  test("restores the last body cursor when select interaction clears selection", () => {
    const editor = document.querySelector("[data-protected-variables-target='editor']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")
    const variableSelect = document.querySelector("[data-protected-variables-target='variableSelect']")
    editor.textContent = "Hello friend"
    textarea.value = "Hello friend"

    const range = document.createRange()
    range.setStart(editor.firstChild, 6)
    range.collapse(true)
    window.getSelection().removeAllRanges()
    window.getSelection().addRange(range)
    editor.dispatchEvent(new Event("keyup"))
    window.getSelection().removeAllRanges()

    variableSelect.value = "%<name>s"
    variableSelect.dispatchEvent(new Event("change"))

    expect(textarea.value).toBe("Hello %<name>sfriend")
  })

  test("appends selected body variable when no cursor was saved", () => {
    const editor = document.querySelector("[data-protected-variables-target='editor']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")
    const variableSelect = document.querySelector("[data-protected-variables-target='variableSelect']")
    editor.textContent = "Hello"
    textarea.value = "Hello"
    window.getSelection().removeAllRanges()

    variableSelect.value = "%<name>s"
    variableSelect.dispatchEvent(new Event("change"))

    expect(textarea.value).toBe("Hello%<name>s")
  })

  test("confirms before switching to Liquid with Standard placeholders", () => {
    jest.spyOn(window, "confirm").mockReturnValue(false)
    const syntaxSelect = document.querySelector("[data-protected-variables-target='syntaxSelect']")
    const variableOption = document.querySelector("[data-protected-variables-target='variableSelect'] [data-legacy-placeholder='%<name>s']")

    syntaxSelect.value = "liquid"
    syntaxSelect.dispatchEvent(new Event("change"))

    expect(window.confirm).toHaveBeenCalledWith("Existing Standard placeholders will not convert. Re-insert variables from the dropdown after switching.")
    expect(syntaxSelect.value).toBe("legacy_percent")
    expect(variableOption.value).toBe("%<name>s")
  })

  test("converts matching Standard placeholders in subject and body", () => {
    jest.spyOn(window, "confirm").mockReturnValue(true)
    const syntaxSelect = document.querySelector("[data-protected-variables-target='syntaxSelect']")
    const subjectInput = document.querySelector("[data-protected-variables-target='subjectInput']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")
    const convertButton = document.querySelector("[data-action='protected-variables#convertStandardPlaceholders']")

    subjectInput.value = "Subject %<name>s"
    textarea.value = "Hello %{name}\nOptional %<nickname>s\nUnknown %<not_allowed>s"
    syntaxSelect.value = "liquid"
    syntaxSelect.dispatchEvent(new Event("change"))
    convertButton.click()

    expect(subjectInput.value).toBe("Subject {{ name }}")
    expect(textarea.value).toBe("Hello {{ name }}\nOptional %<nickname>s\nUnknown %<not_allowed>s")
    expect(Array.from(document.querySelectorAll(".protected-variable")).map((node) => node.textContent)).toContain("{{ name }}")
  })

  test("pastes plain text and syncs it without HTML formatting", () => {
    const editor = document.querySelector("[data-protected-variables-target='editor']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")
    const event = new Event("paste", { bubbles: true, cancelable: true })
    Object.defineProperty(event, "clipboardData", {
      value: {
        getData: (type) => (type === "text/plain" ? "Pasted\nText" : "<strong>Pasted</strong>")
      }
    })

    editor.innerHTML = ""
    window.getSelection().removeAllRanges()
    editor.dispatchEvent(event)

    expect(event.defaultPrevented).toBe(true)
    expect(textarea.value).toBe("Pasted\nText")
    expect(editor.innerHTML).toBe("Pasted\nText")
  })

  test("preserves pasted block formatting when syncing to textarea", () => {
    const editor = document.querySelector("[data-protected-variables-target='editor']")
    const textarea = document.querySelector("[data-protected-variables-target='textarea']")

    editor.innerHTML = '<div>First paragraph</div><p>Second <span class="protected-variable" contenteditable="false">%&lt;name&gt;s</span><br>third line</p><div><span>Fourth line</span></div>'

    editor.dispatchEvent(new Event("input"))

    expect(textarea.value).toBe("First paragraph\nSecond %<name>s\nthird line\nFourth line")
  })
})
