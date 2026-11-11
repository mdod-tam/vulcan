import AdultPickerController from "../../../app/javascript/controllers/users/adult_picker_controller"

jest.mock("../../../app/javascript/utils/visibility", () => ({
  setVisible: jest.fn((element, visible) => {
    if (visible) {
      element.classList.remove("hidden")
    } else {
      element.classList.add("hidden")
    }
  }),
  setFieldValue: jest.fn()
}))

import { setFieldValue, setVisible } from "../../../app/javascript/utils/visibility"

describe("AdultPickerController", () => {
  let controller
  let fixture

  function defineTarget(name, selector, { has = true } = {}) {
    Object.defineProperty(controller, `${name}Target`, {
      value: fixture.querySelector(selector),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, `has${name[0].toUpperCase()}${name.slice(1)}Target`, {
      value: has,
      writable: false,
      configurable: true
    })
  }

  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: jest.fn().mockResolvedValue({
        success: true,
        user: {
          first_name: "Pat",
          middle_initial: "Q",
          last_name: "Applicant",
          date_of_birth: "1980-01-01",
          email: "pat@example.com",
          phone: "555-111-2222",
          physical_address_1: "123 Main Street",
          physical_address_2: "Apt 4",
          city: "Baltimore",
          state: "MD",
          zip_code: "21201",
          locale: "en",
          preferred_means_of_communication: "email",
          referral_source: "clinic"
        },
        last_application_date: "2025-01-01",
        product_names: ["Phone"],
        household_size: 2,
        annual_income: 18000,
        certifying_professional_name: "Dr. Test",
        certifying_professional_phone: "555-333-4444",
        certifying_professional_fax: "555-333-5555",
        certifying_professional_email: "doctor@example.com"
      })
    })

    document.body.innerHTML = `
      <div id="adult-picker-root">
        <div id="searchPane"></div>
        <div id="selectedPane" class="hidden">
          <div class="adult-details-container"></div>
        </div>
        <input type="hidden" id="existingConstituentId" name="existing_constituent_id" value="" />

        <div id="onFileSummary" class="hidden">
          <div id="onFileSummaryContent"></div>
          <button type="button" id="incomeCopyButton" class="hidden">Income</button>
          <button type="button" id="certifyingProfessionalCopyButton" class="hidden">Use last application certifying professional</button>
        </div>

        <div id="contactModeSection" class="hidden">
          <input type="radio" name="contact_info_mode" value="update" checked />
          <input type="radio" name="contact_info_mode" value="on_file" />
        </div>

        <div id="verificationSection" class="hidden">
          <input type="hidden" name="contact_info_verified" value="0" />
          <input type="checkbox" id="verificationCheckbox" name="contact_info_verified" value="1" />
        </div>

        <input type="text" name="constituent[first_name]" value="" />
        <input type="text" name="constituent[middle_initial]" value="" />
        <input type="text" name="constituent[last_name]" value="" />
        <input type="text" name="constituent[date_of_birth]" value="" />
        <input type="email" name="constituent[email]" value="" />
        <input type="text" name="constituent[phone]" value="" />
        <input type="text" name="constituent[physical_address_1]" value="" />
        <input type="text" name="constituent[physical_address_2]" value="" />
        <input type="text" name="constituent[city]" value="" />
        <input type="text" name="constituent[state]" value="" />
        <input type="text" name="constituent[zip_code]" value="" />
        <input type="text" name="constituent[locale]" value="" />
        <input type="text" name="constituent[preferred_means_of_communication]" value="" />
        <input type="text" name="constituent[referral_source]" value="" />
        <input type="text" name="application[household_size]" value="" />
        <input type="text" name="application[annual_income]" value="" />
        <input type="text" name="application[certifying_professional_name]" value="" />
        <input type="text" name="application[certifying_professional_phone]" value="" />
        <input type="text" name="application[certifying_professional_fax]" value="" />
        <input type="text" name="application[certifying_professional_email]" value="" />
      </div>
    `

    fixture = document.querySelector("#adult-picker-root")
    controller = new AdultPickerController()

    Object.defineProperty(controller, "element", {
      value: fixture,
      writable: false,
      configurable: true
    })

    defineTarget("searchPane", "#searchPane")
    defineTarget("selectedPane", "#selectedPane")
    defineTarget("constituentIdField", "#existingConstituentId")
    defineTarget("onFileSummary", "#onFileSummary")
    defineTarget("onFileSummaryContent", "#onFileSummaryContent")
    defineTarget("incomeCopyButton", "#incomeCopyButton")
    defineTarget("certifyingProfessionalCopyButton", "#certifyingProfessionalCopyButton")
    defineTarget("contactModeSection", "#contactModeSection")
    defineTarget("verificationSection", "#verificationSection")
    defineTarget("verificationCheckbox", "#verificationCheckbox")

    Object.defineProperty(controller, "contactModeRadioTargets", {
      value: Array.from(fixture.querySelectorAll('input[name="contact_info_mode"]')),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, "hasContactModeRadioTarget", {
      value: true,
      writable: false,
      configurable: true
    })

    controller.dispatch = jest.fn()
    controller.connect()
  })

  afterEach(() => {
    delete global.fetch
    document.body.innerHTML = ""
    jest.clearAllMocks()
  })

  async function loadSelectedAdultContext() {
    controller.constituentIdFieldTarget.value = '42'
    controller.selectedValue = true
    await controller.fetchAdultContext('42')
  }

  it("does not silently copy application fields when adult context loads", async () => {
    await loadSelectedAdultContext()

    expect(setFieldValue).not.toHaveBeenCalled()
    expect(setVisible).toHaveBeenCalledWith(controller.incomeCopyButtonTarget, true)
    expect(setVisible).toHaveBeenCalledWith(controller.certifyingProfessionalCopyButtonTarget, true)
  })

  // A restored retry has no search result to fill the card from, so the context response must name the applicant.
  it("names the selected applicant when the card was not filled by a click", async () => {
    const box = fixture.querySelector(".adult-details-container")
    expect(box.textContent).toBe("")

    await loadSelectedAdultContext()

    expect(box.textContent).toContain("Pat Q Applicant")
    expect(box.childElementCount).toBeGreaterThan(0)
  })

  // The click path writes richer markup than we can rebuild from JSON, so restoration must not
  // overwrite it.
  it("leaves a card the click path already filled alone", async () => {
    const box = fixture.querySelector(".adult-details-container")
    box.innerHTML = '<div class="chosen">Chosen by click</div>'

    await loadSelectedAdultContext()

    expect(box.textContent).toContain("Chosen by click")
  })

  it("copies household and income fields only when explicitly requested", () => {
    controller._adultApplicationContext = {
      household_size: 2,
      annual_income: 18000
    }

    controller.useLastApplicationIncomeInfo()

    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[household_size]"]', 2)
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[annual_income]"]', 18000)
  })

  it("formats selected adult DOB for text date inputs", async () => {
    await loadSelectedAdultContext()
    controller._autopopulateFields(controller._adultApplicationContext.user)

    expect(fixture.querySelector('input[name="constituent[date_of_birth]"]').value).toBe("01/01/1980")
  })

  it("copies certifying professional fields only when explicitly requested", () => {
    controller._adultApplicationContext = {
      certifying_professional_name: "Dr. Test",
      certifying_professional_phone: "555-333-4444",
      certifying_professional_fax: "555-333-5555",
      certifying_professional_email: "doctor@example.com"
    }

    controller.useLastApplicationCertifyingProfessional()

    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_name]"]', "Dr. Test")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_phone]"]', "555-333-4444")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_fax]"]', "555-333-5555")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_email]"]', "doctor@example.com")
  })

  it("disables existing-adult-only controls when selection is cleared", () => {
    controller._showContactMode()
    controller._showVerification()

    controller.clearSelection()

    fixture.querySelectorAll("#contactModeSection input, #verificationSection input").forEach(field => {
      expect(field.disabled).toBe(true)
    })
  })

  describe("context response ownership", () => {
    let requests

    const context = (id, locale = 'en', income = 11000) => ({
      success: true,
      user: {
        first_name: `Applicant ${id}`, last_name: 'Selected', date_of_birth: '1980-01-01',
        email: `applicant${id}@example.com`, phone: '4105550100',
        physical_address_1: `${id} Selected Street`, physical_address_2: `Apt ${id}`,
        city: `City ${id}`, state: 'MD', zip_code: '21201', locale,
        preferred_means_of_communication: 'written'
      },
      household_size: Number(id), annual_income: income,
      certifying_professional_name: `Professional ${id}`
    })

    beforeEach(() => {
      requests = []
      global.fetch.mockImplementation(() => new Promise((resolve, reject) => requests.push({ resolve, reject })))
    })

    async function flushResponses() {
      await Promise.resolve()
      await Promise.resolve()
    }

    async function respond(index, data) {
      requests[index].resolve({ ok: true, json: async () => data })
      await flushResponses()
    }

    function selectAdult(id) {
      controller.selectAdult(id, `<div>Applicant ${id}</div>`)
    }

    function expectCurrentContext(id, locale = 'en', income = 11000) {
      expect(controller.constituentIdFieldTarget.value).toBe(id)
      expect(fixture.querySelector('[name="constituent[physical_address_1]"]').value).toBe(`${id} Selected Street`)
      expect(fixture.querySelector('[name="constituent[locale]"]').value).toBe(locale)
      expect(controller._onFileData.physical_address_1).toBe(`${id} Selected Street`)
      expect(controller.onFileSummaryContentTarget).toHaveTextContent(`Applicant ${id}`)
      expect(controller._adultApplicationContext.annual_income).toBe(income)
      expect(controller.contactModeSectionTarget).not.toHaveClass('hidden')
      expect(controller.verificationSectionTarget).not.toHaveClass('hidden')
    }

    it("keeps fields, on-file data, and copy sources on the current selection", async () => {
      selectAdult('1')
      selectAdult('2')
      await respond(1, context('2', 'es', 22000))
      await respond(0, context('1'))

      expectCurrentContext('2', 'es', 22000)
      controller.useLastApplicationIncomeInfo()
      controller.useLastApplicationCertifyingProfessional()
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[annual_income]"]', 22000)
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_name]"]', 'Professional 2')
    })

    it("rejects an earlier response when the same adult is selected again", async () => {
      selectAdult('1')
      selectAdult('2')
      selectAdult('1')
      await respond(2, context('1', 'es', 33000))
      await respond(0, context('1'))

      expectCurrentContext('1', 'es', 33000)
    })

    it("checks ownership after delayed JSON parsing", async () => {
      let resolveJson
      selectAdult('1')
      requests[0].resolve({ ok: true, json: () => new Promise(resolve => { resolveJson = resolve }) })
      await flushResponses()
      selectAdult('2')
      await respond(1, context('2', 'es', 22000))
      resolveJson(context('1'))
      await flushResponses()

      expectCurrentContext('2', 'es', 22000)
    })

    it("removes previous context and verification while a replacement loads", async () => {
      selectAdult('1')
      await respond(0, context('1'))
      controller.verificationCheckboxTarget.checked = true
      selectAdult('2')

      controller.useLastApplicationIncomeInfo()
      controller.useLastApplicationCertifyingProfessional()

      expect(setFieldValue).not.toHaveBeenCalled()
      expect(controller._adultApplicationContext).toBeNull()
      expect(controller._onFileData).toEqual({})
      expect(controller.onFileSummaryTarget).toHaveClass('hidden')
      expect(controller.verificationCheckboxTarget.checked).toBe(false)
    })

    it.each(['clearSelection', 'createNewApplicant', 'disconnect'])("invalidates pending responses on %s", async action => {
      selectAdult('1')
      controller[action]()
      await respond(0, context('1'))

      expect(controller._adultApplicationContext).toBeNull()
      expect(controller._onFileData).toEqual({})
      expect(controller.onFileSummaryTarget).toHaveClass('hidden')
      expect(fixture.querySelector('[name="constituent[physical_address_1]"]').value).toBe('')
    })

    it("does not log an obsolete request failure or disturb current context", async () => {
      const warning = jest.spyOn(console, 'warn').mockImplementation(() => {})
      try {
        selectAdult('1')
        selectAdult('2')
        await respond(1, context('2', 'es', 22000))
        requests[0].reject(new Error('Previous request failed'))
        await flushResponses()

        expectCurrentContext('2', 'es', 22000)
        expect(warning).not.toHaveBeenCalled()
      } finally {
        warning.mockRestore()
      }
    })

    it("leaves no previous adult context available after the current request fails", async () => {
      const warning = jest.spyOn(console, 'warn').mockImplementation(() => {})
      try {
        selectAdult('1')
        await respond(0, context('1'))
        selectAdult('2')
        requests[1].reject(new Error('Current request failed'))
        await flushResponses()

        expect(controller._adultApplicationContext).toBeNull()
        expect(controller._onFileData).toEqual({})
        expect(controller.onFileSummaryTarget).toHaveClass('hidden')
        expect(controller.verificationCheckboxTarget.checked).toBe(false)
        expect(warning).toHaveBeenCalledTimes(1)
      } finally {
        warning.mockRestore()
      }
    })

    it("rejects a response from before disconnect even after reconnecting to the same adult", async () => {
      selectAdult('1')
      controller.disconnect()
      controller.connect()
      await respond(1, context('1', 'es', 33000))
      await respond(0, context('1'))

      expectCurrentContext('1', 'es', 33000)
    })

    it("preserves restored corrections and populates a replacement adult after clearing", async () => {
      fixture.dataset.adultPickerRestoredValue = 'true'
      controller.constituentIdFieldTarget.value = '1'
      fixture.querySelector('[name="constituent[physical_address_1]"]').value = 'Corrected on paper'
      fixture.querySelector('[name="constituent[locale]"]').value = 'es'
      controller.verificationCheckboxTarget.checked = true
      controller.connect()
      await respond(0, context('1'))

      expect(fixture.querySelector('[name="constituent[physical_address_1]"]').value).toBe('Corrected on paper')
      expect(fixture.querySelector('[name="constituent[locale]"]').value).toBe('es')
      expect(controller.verificationCheckboxTarget.checked).toBe(true)
      expect(controller._onFileData.physical_address_1).toBe('1 Selected Street')

      controller.clearSelection()
      selectAdult('2')
      await respond(1, context('2'))

      expectCurrentContext('2')
      expect(controller.verificationCheckboxTarget.checked).toBe(false)
    })
  })
})
