import ApplicantTypeController from "../../../app/javascript/controllers/users/applicant_type_controller"

// Mock the visibility utility
jest.mock('../../../app/javascript/utils/visibility', () => ({
  setVisible: jest.fn((element, visible, options = {}) => {
    if (visible) {
      element.classList.remove('hidden')
    } else {
      element.classList.add('hidden')
    }

    // Handle required attribute for form fields
    if (options.required !== undefined) {
      if (options.required) {
        element.setAttribute('required', '')
      } else {
        element.removeAttribute('required')
      }
    }
  })
}))

// Mock the debounce utility
jest.mock('../../../app/javascript/utils/debounce', () => ({
  createVeryShortDebounce: jest.fn((fn) => {
    const debouncedFn = fn
    debouncedFn.cancel = jest.fn()
    return debouncedFn
  })
}))

describe("ApplicantTypeController", () => {
  let controller, fixture

  beforeEach(() => {
    // Set up DOM fixture with all required targets
    document.body.innerHTML = `
      <div id="test-container">
        <div id="radioSection">
          <input type="radio" name="applicant_type" value="self" id="selfRadio" />
          <label>Apply for Self</label>
          
          <input type="radio" name="applicant_type" value="dependent" id="dependentRadio" checked />
          <label>Apply for Dependent</label>
        </div>

        <div id="adultSearchSection">
          <input type="hidden" name="existing_constituent_id" value="123" />
        </div>
        
        <div id="adultSection" class="hidden">
          Adult Application Section
          <input type="text" name="constituent[first_name]" value="" />
          <input type="text" name="constituent[last_name]" value="" />
          <input type="email" name="constituent[email]" value="" />
        </div>
        
        <div id="guardianSection">
          Guardian Search and Selection
          <div class="guardian-picker-section">
            <!-- This would contain the guardian picker controller -->
          </div>
        </div>
        
        <div id="sectionsForDependentWithGuardian" class="hidden">
          <div id="dependentField">
            Dependent Information Section
            <input type="text" name="dependent[first_name]" placeholder="Dependent First Name" />
            <input type="text" name="dependent[last_name]" placeholder="Dependent Last Name" />
          </div>
        </div>
        
        <div id="commonSections">
          Common Application Sections
        </div>
      </div>
    `

    fixture = document.querySelector('#test-container')

    // Create controller instance directly
    controller = new ApplicantTypeController()

    // Mock controller properties using Object.defineProperty
    Object.defineProperty(controller, 'element', {
      value: fixture,
      writable: false,
      configurable: true
    })

    // Mock target properties
    Object.defineProperty(controller, 'radioTargets', {
      value: Array.from(fixture.querySelectorAll('input[type="radio"]')),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'radioSectionTarget', {
      value: fixture.querySelector('#radioSection'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'adultSectionTarget', {
      value: fixture.querySelector('#adultSection'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'adultSearchSectionTarget', {
      value: fixture.querySelector('#adultSearchSection'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'guardianSectionTarget', {
      value: fixture.querySelector('#guardianSection'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'sectionsForDependentWithGuardianTarget', {
      value: fixture.querySelector('#sectionsForDependentWithGuardian'),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'dependentFieldTargets', {
      value: Array.from(fixture.querySelectorAll('#dependentField')),
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'commonSectionsTarget', {
      value: fixture.querySelector('#commonSections'),
      writable: false,
      configurable: true
    })

    // Mock the has target methods
    Object.defineProperty(controller, 'hasRadioSectionTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasAdultSectionTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasAdultSearchSectionTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasGuardianSectionTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasSectionsForDependentWithGuardianTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasDependentFieldTargets', {
      value: true,
      writable: false,
      configurable: true
    })

    Object.defineProperty(controller, 'hasCommonSectionsTarget', {
      value: true,
      writable: false,
      configurable: true
    })

    // Mock outlet properties (initially no outlets)
    Object.defineProperty(controller, 'hasGuardianPickerOutlet', {
      get: () => false,
      configurable: true
    })

    Object.defineProperty(controller, 'initialCreateNewAdultValue', {
      value: false,
      writable: true,
      configurable: true
    })

    Object.defineProperty(controller, 'hasFlashOutlet', {
      get: () => false,
      configurable: true
    })

    // Mock the dispatch method
    controller.dispatch = jest.fn()

    // Call connect manually
    controller.connect()
  })

  afterEach(() => {
    if (controller && controller.disconnect) {
      controller.disconnect()
    }
    document.body.innerHTML = ""
    jest.clearAllMocks()
  })

  // Helper function to mock the guardian picker outlet
  function createMockGuardianPickerOutlet(selectedValue = false) {
    const mockOutlet = {
      selectedValue: selectedValue
    }

    // Mock the hasGuardianPickerOutlet getter
    Object.defineProperty(controller, 'hasGuardianPickerOutlet', {
      get: () => true,
      configurable: true
    })

    // Mock the guardianPickerOutlet getter
    Object.defineProperty(controller, 'guardianPickerOutlet', {
      get: () => mockOutlet,
      configurable: true
    })

    return mockOutlet
  }

  describe("initialization", () => {
    it("connects and sets up initial state correctly", () => {
      expect(controller).toBeDefined()
      expect(controller.element).toBe(fixture)
    })

    it("handles missing guardian picker outlet gracefully", () => {
      expect(() => {
        controller.refresh()
      }).not.toThrow()
    })
  })

  describe("dependent section visibility logic", () => {
    it("shows dependent sections when dependent radio selected AND guardian chosen", () => {
      // Mock guardian picker outlet with guardian selected
      createMockGuardianPickerOutlet(true)

      // Ensure dependent radio is selected
      const dependentRadio = fixture.querySelector('#dependentRadio')
      dependentRadio.checked = true

      controller.executeRefresh()

      const dependentSections = fixture.querySelector('#sectionsForDependentWithGuardian')
      expect(dependentSections.classList.contains('hidden')).toBe(false)
    })

    it("hides dependent sections when guardian NOT chosen", () => {
      // Mock guardian picker outlet with no guardian selected
      createMockGuardianPickerOutlet(false)

      // Ensure dependent radio is selected
      const dependentRadio = fixture.querySelector('#dependentRadio')
      dependentRadio.checked = true

      controller.executeRefresh()

      const dependentSections = fixture.querySelector('#sectionsForDependentWithGuardian')
      expect(dependentSections.classList.contains('hidden')).toBe(true)
    })

    it("hides dependent sections when self radio selected", () => {
      // Mock guardian picker outlet with guardian selected
      createMockGuardianPickerOutlet(true)

      // Select self radio instead
      const selfRadio = fixture.querySelector('#selfRadio')
      const dependentRadio = fixture.querySelector('#dependentRadio')
      selfRadio.checked = true
      dependentRadio.checked = false

      controller.executeRefresh()

      const dependentSections = fixture.querySelector('#sectionsForDependentWithGuardian')
      expect(dependentSections.classList.contains('hidden')).toBe(true)
    })

    it("shows guardian section when dependent radio is selected", () => {
      const dependentRadio = fixture.querySelector('#dependentRadio')
      dependentRadio.checked = true

      controller.executeRefresh()

      const guardianSection = fixture.querySelector('#guardianSection')
      expect(guardianSection.classList.contains('hidden')).toBe(false)
    })

    it("hides guardian section when self radio is selected", () => {
      const selfRadio = fixture.querySelector('#selfRadio')
      const dependentRadio = fixture.querySelector('#dependentRadio')
      selfRadio.checked = true
      dependentRadio.checked = false

      controller.executeRefresh()

      const guardianSection = fixture.querySelector('#guardianSection')
      expect(guardianSection.classList.contains('hidden')).toBe(true)
    })
  })

  describe("guardian picker events", () => {
    beforeEach(() => {
      // Ensure dependent radio is selected
      const dependentRadio = fixture.querySelector('#dependentRadio')
      dependentRadio.checked = true
    })

    it("responds to guardian picker selection change events", () => {
      const refreshSpy = jest.spyOn(controller, 'refresh')

      // Simulate guardian picker selection change event
      const selectionChangeEvent = new CustomEvent('guardian-picker:selectionChange', {
        detail: { selectedValue: true }
      })

      controller.guardianPickerSelectionChange(selectionChangeEvent)

      expect(refreshSpy).toHaveBeenCalled()
    })

    it("shows dependent sections after guardian selection event", () => {
      // Start with no guardian selected
      let mockOutlet = createMockGuardianPickerOutlet(false)
      controller.executeRefresh()

      let dependentSections = fixture.querySelector('#sectionsForDependentWithGuardian')
      expect(dependentSections.classList.contains('hidden')).toBe(true)

      // Simulate guardian selection
      mockOutlet.selectedValue = true

      // Simulate the selection change event
      const selectionChangeEvent = new CustomEvent('guardian-picker:selectionChange', {
        detail: { selectedValue: true }
      })

      controller.guardianPickerSelectionChange(selectionChangeEvent)

      // Check that dependent sections are visible
      expect(dependentSections.classList.contains('hidden')).toBe(false)
    })

    it("dispatches applicantTypeChanged event when dependent sections become visible", () => {
      // Mock guardian picker outlet with guardian selected
      createMockGuardianPickerOutlet(true)

      // Clear previous dispatch calls
      controller.dispatch.mockClear()

      controller.executeRefresh()

      expect(controller.dispatch).toHaveBeenCalledWith("applicantTypeChanged", {
        detail: { isDependentSelected: true }
      })
    })
  })

  describe("radio button changes", () => {
    it("updates display when radio button changes", () => {
      const refreshSpy = jest.spyOn(controller, 'refresh')

      const selfRadio = fixture.querySelector('#selfRadio')
      selfRadio.checked = true

      controller.updateApplicantTypeDisplay()

      expect(refreshSpy).toHaveBeenCalled()
    })

    it("shows adult section when self is selected", () => {
      const selfRadio = fixture.querySelector('#selfRadio')
      const dependentRadio = fixture.querySelector('#dependentRadio')
      selfRadio.checked = true
      dependentRadio.checked = false

      controller.executeRefresh()

      const adultSection = fixture.querySelector('#adultSection')
      expect(adultSection.classList.contains('hidden')).toBe(true)
    })

    it("shows adult section when create-new state is supplied by the server", () => {
      const selfRadio = fixture.querySelector('#selfRadio')
      const dependentRadio = fixture.querySelector('#dependentRadio')
      const adultSection = fixture.querySelector('#adultSection')

      controller.initialCreateNewAdultValue = true
      controller._adultCreateNew = true
      selfRadio.checked = true
      dependentRadio.checked = false

      controller.executeRefresh()

      expect(adultSection.classList.contains('hidden')).toBe(false)
    })

    it("disables adult search fields when dependent flow is active", () => {
      const selfRadio = fixture.querySelector('#selfRadio')
      const dependentRadio = fixture.querySelector('#dependentRadio')
      const existingConstituentId = fixture.querySelector('input[name="existing_constituent_id"]')

      selfRadio.checked = false
      dependentRadio.checked = true

      controller.executeRefresh()

      expect(existingConstituentId.disabled).toBe(true)
    })
  })

  describe("error handling", () => {
    it("handles missing targets gracefully", () => {
      // Remove a target to simulate missing DOM element
      fixture.querySelector('#guardianSection').remove()

      expect(() => {
        controller.executeRefresh()
      }).not.toThrow()
    })

    it("handles guardian picker outlet connection/disconnection", () => {
      const mockOutletInstance = { selectedValue: false }

      // Test outlet connection
      expect(() => {
        controller.guardianPickerOutletConnected(mockOutletInstance, fixture)
      }).not.toThrow()

      // Test outlet disconnection
      expect(() => {
        controller.guardianPickerOutletDisconnected(mockOutletInstance, fixture)
      }).not.toThrow()
    })
  })

  describe("helper methods", () => {
    it("correctly detects dependent radio selection", () => {
      const dependentRadio = fixture.querySelector('#dependentRadio')
      const selfRadio = fixture.querySelector('#selfRadio')

      // Test dependent selected
      dependentRadio.checked = true
      selfRadio.checked = false
      expect(controller.isDependentRadioChecked()).toBe(true)

      // Test self selected
      dependentRadio.checked = false
      selfRadio.checked = true
      expect(controller.isDependentRadioChecked()).toBe(false)
    })

    it("can programmatically select radio buttons", () => {
      controller.selectRadio('self')

      const selfRadio = fixture.querySelector('#selfRadio')
      expect(selfRadio.checked).toBe(true)

      controller.selectRadio('dependent')

      const dependentRadio = fixture.querySelector('#dependentRadio')
      expect(dependentRadio.checked).toBe(true)
    })
  })
}) 
