import GuardianPickerController from "../../../app/javascript/controllers/users/guardian_picker_controller"

jest.mock('../../../app/javascript/utils/visibility', () => ({
  setVisible: jest.fn((element, visible) => {
    if (visible) {
      element.classList.remove('hidden')
    } else {
      element.classList.add('hidden')
    }
  }),
  setFieldValue: jest.fn()
}))

import { setFieldValue, setVisible } from "../../../app/javascript/utils/visibility"

describe("GuardianPickerController", () => {
  let controller, fixture
  
  beforeEach(() => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      json: jest.fn()
    })

    document.body.innerHTML = `
      <div id="test-container">
        <div id="searchPane" class="">
          <input type="text" placeholder="Search guardians..." />
        </div>
        
        <div id="selectedPane" class="hidden">
          <div class="guardian-details-container"></div>
          <div id="lastApplicationSummary" class="hidden">
            <div id="lastApplicationSource"></div>
            <div id="lastApplicationDetails"></div>
            <button type="button" id="incomeCopyButton">Income</button>
            <button type="button" id="certifyingProfessionalCopyButton">Use last application certifying professional</button>
          </div>
          <button type="button">Clear Selection</button>
        </div>
        
        <input type="hidden" id="guardianIdField" name="guardian_id" value="" />
        <input type="hidden" id="dependentIdField" name="dependent_id" value="" />
        <input type="radio" id="dependentRadio" name="applicant_type" value="dependent" />
        <turbo-frame id="dependent_info_form"></turbo-frame>
        <input type="text" name="application[household_size]" value="" />
        <input type="text" name="application[annual_income]" value="" />
        <input type="text" name="application[certifying_professional_name]" value="" />
        <input type="text" name="application[certifying_professional_phone]" value="" />
        <input type="text" name="application[certifying_professional_fax]" value="" />
        <input type="text" name="application[certifying_professional_email]" value="" />
      </div>
    `
    
    fixture = document.querySelector('#test-container')
    
    controller = new GuardianPickerController()
    
    // No Stimulus application runs here, so the targets Stimulus would define are set directly on the instance.
    Object.defineProperty(controller, 'element', {
      value: fixture,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'searchPaneTarget', {
      value: fixture.querySelector('#searchPane'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'selectedPaneTarget', {
      value: fixture.querySelector('#selectedPane'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'guardianIdFieldTarget', {
      value: fixture.querySelector('#guardianIdField'),
      writable: true,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasSearchPaneTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasSelectedPaneTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasGuardianIdFieldTarget', {
      value: true,
      writable: true,
      configurable: true
    })

    Object.defineProperty(controller, 'dependentIdFieldTarget', {
      value: fixture.querySelector('#dependentIdField'),
      configurable: true
    })
    Object.defineProperty(controller, 'hasDependentIdFieldTarget', { value: true, configurable: true })
    Object.defineProperty(controller, 'applicantTypeRadioDependentTarget', {
      value: fixture.querySelector('#dependentRadio'),
      configurable: true
    })
    Object.defineProperty(controller, 'hasApplicantTypeRadioDependentTarget', { value: true, configurable: true })
    
    controller.dispatch = jest.fn()
    
    controller.connect()
  })
  
  afterEach(() => {
    delete global.fetch
    document.body.innerHTML = ""
    jest.clearAllMocks()
  })
  
  describe("initialization", () => {
    it("initializes with no selection when guardianIdField is empty", () => {
      expect(controller.selectedValue).toBe(false)
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, true)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, false)
    })
    
    it("initializes with selection when guardianIdField has value", () => {
      const idField = fixture.querySelector('#guardianIdField')
      idField.value = "123"
      
      const newController = new GuardianPickerController()
      
      Object.defineProperty(newController, 'element', {
        value: fixture,
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'searchPaneTarget', {
        value: fixture.querySelector('#searchPane'),
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'selectedPaneTarget', {
        value: fixture.querySelector('#selectedPane'),
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'guardianIdFieldTarget', {
        value: idField,
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'hasSearchPaneTarget', {
        value: true,
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'hasSelectedPaneTarget', {
        value: true,
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(newController, 'hasGuardianIdFieldTarget', {
        value: true,
        writable: false,
        configurable: true
      })
      
      newController.dispatch = jest.fn()
      newController.connect()
      
      expect(newController.selectedValue).toBe(true)
    })
  })
  
  describe("selectGuardian", () => {
    it("sets the guardian ID and updates UI", () => {
      const displayHTML = '<div>John Doe<br>john@example.com</div>'
      
      controller.selectGuardian("456", displayHTML)
      
      const container = fixture.querySelector('.guardian-details-container')
      
      expect(controller.guardianIdFieldTarget.value).toBe("456")
      expect(container.innerHTML).toBe(displayHTML)
      expect(controller.selectedValue).toBe(true)
    })
    
    it("toggles panes correctly after selection", () => {
      jest.clearAllMocks() // Clear initial calls from connect()
      
      controller.selectGuardian("456", "<div>Guardian Info</div>")
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, false)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, true)
    })
    
    it("dispatches selectionChange event", () => {
      jest.useFakeTimers()
      
      controller.selectGuardian("456", "<div>Guardian Info</div>")

      expect(controller.dispatch).toHaveBeenCalledWith("selectionChange", {
        detail: { selectedValue: true }
      })
      
      jest.useRealTimers()
    })

    it("does not copy application fields on guardian selection", () => {
      controller.selectGuardian("456", "<div>Guardian Info</div>")

      expect(setFieldValue).not.toHaveBeenCalled()
    })
  })

  describe("clearSelection", () => {
    beforeEach(() => {
      controller.selectGuardian("456", "<div>Guardian Info</div>")
      jest.clearAllMocks() // Clear the mocks after setup
    })
    
    it("clears the guardian ID and resets UI", () => {
      controller.clearSelection()
      
      expect(controller.guardianIdFieldTarget.value).toBe("")
      expect(controller.selectedValue).toBe(false)
    })
    
    it("toggles panes correctly after clearing", () => {
      controller.clearSelection()
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, true)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, false)
    })
    
    it("dispatches selectionChange event with false value", () => {
      // A fresh mock keeps earlier calls out of the dispatch assertion.
      const freshDispatchMock = jest.fn()
      controller.dispatch = freshDispatchMock
      
      controller.clearSelection()

      expect(freshDispatchMock).toHaveBeenCalledWith("selectionChange", {
        detail: { selectedValue: false }
      })
      
      jest.useRealTimers()
    })
  })
  
  describe("error handling", () => {
    it("handles missing guardianIdField target gracefully", () => {
      Object.defineProperty(controller, 'guardianIdFieldTarget', {
        value: null,
        writable: false,
        configurable: true
      })
      
      Object.defineProperty(controller, 'hasGuardianIdFieldTarget', {
        value: false,
        writable: false,
        configurable: true
      })
      
      expect(() => {
        controller.selectGuardian("456", "<div>Guardian Info</div>")
      }).not.toThrow()
      
      expect(controller.selectedValue).toBe(true)
    })
    
    it("handles missing guardian-details-container gracefully", () => {
      const container = fixture.querySelector('.guardian-details-container')
      container.remove()
      
      expect(() => {
        controller.selectGuardian("456", "<div>Guardian Info</div>")
      }).not.toThrow()
    })
  })
  
  describe("internal methods", () => {
    it("togglePanes method works correctly", () => {
      jest.clearAllMocks()
      
      controller.selectedValue = true
      controller.togglePanes()
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, false)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, true)
      
      jest.clearAllMocks()
      
      controller.selectedValue = false
      controller.togglePanes()
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, true)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, false)
    })
    


    it("copies last application income fields only when explicitly requested", () => {
      controller._lastApplicationContext = {
        household_size: 2,
        annual_income: 18000
      }

      controller.useLastApplicationIncomeInfo()

      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[household_size]"]', 2)
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[annual_income]"]', 18000)
    })

    it("copies last application certifying professional fields only when explicitly requested", () => {
      controller._lastApplicationContext = {
        certifying_professional_name: 'Dr. Test',
        certifying_professional_phone: '555-111-2222',
        certifying_professional_fax: '555-333-4444',
        certifying_professional_email: 'doctor@example.com'
      }

      controller.useLastApplicationCertifyingProfessional()

      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_name]"]', 'Dr. Test')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_phone]"]', '555-111-2222')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_fax]"]', '555-333-4444')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[certifying_professional_email]"]', 'doctor@example.com')
    })
  })
})
