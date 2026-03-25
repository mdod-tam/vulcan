import GuardianPickerController from "../../../app/javascript/controllers/users/guardian_picker_controller"

// Mock the visibility utility
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

    // Set up DOM fixture
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
            <button type="button" id="medicalCopyButton">Medical</button>
          </div>
          <button type="button">Clear Selection</button>
        </div>
        
        <input type="hidden" id="guardianIdField" name="guardian_id" value="" />
        <input type="text" name="application[household_size]" value="" />
        <input type="text" name="application[annual_income]" value="" />
        <input type="text" name="application[medical_provider_name]" value="" />
        <input type="text" name="application[medical_provider_phone]" value="" />
        <input type="text" name="application[medical_provider_fax]" value="" />
        <input type="text" name="application[medical_provider_email]" value="" />
      </div>
    `
    
    fixture = document.querySelector('#test-container')
    
    // Create controller instance directly
    controller = new GuardianPickerController()
    
    // Mock controller properties using Object.defineProperty
    Object.defineProperty(controller, 'element', {
      value: fixture,
      writable: false,
      configurable: true
    })
    
    // Mock target properties
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
      writable: true, // This might be modified in tests
      configurable: true
    })
    
    // Mock the has target methods
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
      writable: true, // This might be modified in tests
      configurable: true
    })
    
    // Mock the dispatch method
    controller.dispatch = jest.fn()
    
    // Call connect manually
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
      // Create a new controller with pre-filled value
      const idField = fixture.querySelector('#guardianIdField')
      idField.value = "123"
      
      const newController = new GuardianPickerController()
      
      // Mock the new controller properties
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
      
      // Fast-forward timers to trigger the delayed dispatch
      jest.advanceTimersByTime(20)
      
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
      // Start with a selection
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
      // Don't clear mocks for this test since we need to check dispatch
      const freshDispatchMock = jest.fn()
      controller.dispatch = freshDispatchMock
      
      // Reset the debounce timer to allow the dispatch to happen
      controller._lastDispatch_selectionChange = 0
      
      jest.useFakeTimers()
      
      controller.clearSelection()
      
      // Fast-forward timers to trigger the delayed dispatch
      jest.advanceTimersByTime(20)
      
      expect(freshDispatchMock).toHaveBeenCalledWith("selectionChange", {
        detail: { selectedValue: false }
      })
      
      jest.useRealTimers()
    })
  })
  
  describe("event debouncing", () => {
    it("prevents rapid-fire event dispatching", () => {
      jest.useFakeTimers()
      
      // Rapid selections
      controller.selectGuardian("1", "<div>Guardian 1</div>")
      controller.selectGuardian("2", "<div>Guardian 2</div>")
      controller.selectGuardian("3", "<div>Guardian 3</div>")
      
      // Fast-forward timers
      jest.advanceTimersByTime(20)
      
      // Should only dispatch once due to debouncing
      expect(controller.dispatch).toHaveBeenCalledTimes(1)
      expect(controller.dispatch).toHaveBeenCalledWith("selectionChange", {
        detail: { selectedValue: true }
      })
      
      jest.useRealTimers()
    })
  })
  
  describe("error handling", () => {
    it("handles missing guardianIdField target gracefully", () => {
      // Simulate missing target by redefining properties
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
      
      // Test with selectedValue = true
      controller.selectedValue = true
      controller.togglePanes()
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, false)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, true)
      
      jest.clearAllMocks()
      
      // Test with selectedValue = false
      controller.selectedValue = false
      controller.togglePanes()
      
      expect(setVisible).toHaveBeenCalledWith(controller.searchPaneTarget, true)
      expect(setVisible).toHaveBeenCalledWith(controller.selectedPaneTarget, false)
    })
    
    it("dispatchSelectionChange method includes debouncing", () => {
      jest.useFakeTimers()
      
      // Call multiple times rapidly
      controller.dispatchSelectionChange()
      controller.dispatchSelectionChange()
      controller.dispatchSelectionChange()
      
      // Should not dispatch yet due to debouncing
      expect(controller.dispatch).not.toHaveBeenCalled()
      
      // Fast-forward past debounce period
      jest.advanceTimersByTime(20)
      
      // Should dispatch only once
      expect(controller.dispatch).toHaveBeenCalledTimes(1)
      
      jest.useRealTimers()
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

    it("copies last application medical provider fields only when explicitly requested", () => {
      controller._lastApplicationContext = {
        medical_provider_name: 'Dr. Test',
        medical_provider_phone: '555-111-2222',
        medical_provider_fax: '555-333-4444',
        medical_provider_email: 'doctor@example.com'
      }

      controller.useLastApplicationMedicalProvider()

      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_name]"]', 'Dr. Test')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_phone]"]', '555-111-2222')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_fax]"]', '555-333-4444')
      expect(setFieldValue).toHaveBeenCalledWith('input[name="application[medical_provider_email]"]', 'doctor@example.com')
    })
  })
})
