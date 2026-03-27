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

jest.mock("../../../app/javascript/utils/debounce", () => ({
  debouncedDispatch: jest.fn()
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
        medical_provider_name: "Dr. Test",
        medical_provider_phone: "555-333-4444",
        medical_provider_fax: "555-333-5555",
        medical_provider_email: "doctor@example.com"
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
          <button type="button" id="medicalCopyButton" class="hidden">Medical</button>
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
        <input type="text" name="application[medical_provider_name]" value="" />
        <input type="text" name="application[medical_provider_phone]" value="" />
        <input type="text" name="application[medical_provider_fax]" value="" />
        <input type="text" name="application[medical_provider_email]" value="" />
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
    defineTarget("medicalCopyButton", "#medicalCopyButton")
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

  it("does not silently copy application fields when adult context loads", async () => {
    await controller.fetchAdultContext("42")

    expect(setFieldValue).not.toHaveBeenCalled()
    expect(setVisible).toHaveBeenCalledWith(controller.incomeCopyButtonTarget, true)
    expect(setVisible).toHaveBeenCalledWith(controller.medicalCopyButtonTarget, true)
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

  it("copies medical provider fields only when explicitly requested", () => {
    controller._adultApplicationContext = {
      medical_provider_name: "Dr. Test",
      medical_provider_phone: "555-333-4444",
      medical_provider_fax: "555-333-5555",
      medical_provider_email: "doctor@example.com"
    }

    controller.useLastApplicationMedicalProvider()

    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_name]"]', "Dr. Test")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_phone]"]', "555-333-4444")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_fax]"]', "555-333-5555")
    expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_email]"]', "doctor@example.com")
  })

  it("disables existing-adult-only controls when selection is cleared", () => {
    controller._showContactMode()
    controller._showVerification()

    controller.clearSelection()

    fixture.querySelectorAll("#contactModeSection input, #verificationSection input").forEach(field => {
      expect(field.disabled).toBe(true)
    })
  })
})
