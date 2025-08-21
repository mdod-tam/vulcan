import UserSearchController from "../../../app/javascript/controllers/admin/user_search_controller"

// Mock the rails request service
jest.mock('../../../app/javascript/services/rails_request', () => ({
  railsRequest: {
    perform: jest.fn(),
    cancel: jest.fn()
  }
}))

// Mock the visibility utility
jest.mock('../../../app/javascript/utils/visibility', () => ({
  setVisible: jest.fn((element, visible) => {
    if (visible) {
      element.classList.remove('hidden')
    } else {
      element.classList.add('hidden')
    }
  })
}))

import { railsRequest } from "../../../app/javascript/services/rails_request"

// Mock fetch
global.fetch = jest.fn()

describe("UserSearchController", () => {
  let controller, fixture
  
  beforeEach(() => {
    // Set up DOM fixture for guardian creation
    document.body.innerHTML = `
      <div id="test-container">
        <input type="text" id="searchInput" placeholder="Search guardians..." />
        
        <div id="searchResults" class="hidden"></div>
        
        <div data-controller="admin-user-search"
             data-admin-user-search-search-url-value="/admin/users/search"
             data-admin-user-search-create-user-url-value="/admin/users"
             data-admin-user-search-role-value="guardian">
          <input type="text" name="guardian_attributes[first_name]" value="" />
          <input type="text" name="guardian_attributes[last_name]" value="" />
          <input type="email" name="guardian_attributes[email]" value="" />
          <input type="tel" name="guardian_attributes[phone]" value="" />
          <input type="text" name="guardian_attributes[physical_address_1]" value="" />
          <input type="text" name="guardian_attributes[city]" value="" />
          <select name="guardian_attributes[state]">
            <option value="MD">Maryland</option>
          </select>
          <input type="text" name="guardian_attributes[zip_code]" value="" />
          <input type="date" name="guardian_attributes[date_of_birth]" value="" />
          <input type="radio" name="guardian_attributes[phone_type]" value="mobile" checked />
          <input type="radio" name="guardian_attributes[communication_preference]" value="email" checked />
          
          <button type="button" id="createButton">Save Guardian</button>
        </div>
        
        <button type="button" id="clearSearchButton">Clear Search</button>
      </div>
    `
    
    fixture = document.querySelector('#test-container')
    
    // Create controller instance directly
    controller = new UserSearchController()
    
    // Mock controller properties using Object.defineProperty
    Object.defineProperty(controller, 'element', {
      value: fixture,
      writable: false,
      configurable: true
    })
    
    // Mock target properties
    Object.defineProperty(controller, 'searchInputTarget', {
      value: fixture.querySelector('#searchInput'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'searchResultsTarget', {
      value: fixture.querySelector('#searchResults'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'guardianFormTarget', {
      value: fixture.querySelector('[data-controller="admin-user-search"]'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'createButtonTarget', {
      value: fixture.querySelector('#createButton'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'clearSearchButtonTarget', {
      value: fixture.querySelector('#clearSearchButton'),
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'guardianFormFieldTargets', {
      value: Array.from(fixture.querySelectorAll('input[name^="guardian_attributes"], select[name^="guardian_attributes"]')),
      writable: false,
      configurable: true
    })
    
    // Mock the has target methods
    Object.defineProperty(controller, 'hasSearchInputTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasSearchResultsTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasGuardianFormTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasCreateButtonTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasClearSearchButtonTarget', {
      value: true,
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasGuardianFormFieldTargets', {
      value: true,
      writable: false,
      configurable: true
    })
    
    // Mock data values
    Object.defineProperty(controller, 'searchUrlValue', {
      value: '/admin/users/search',
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'createUserUrlValue', {
      value: '/admin/users',
      writable: false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'defaultRoleValue', {
      value: 'guardian',
      writable: false,
      configurable: true
    })
    
    // Mock inherited properties from BaseFormController
    Object.defineProperty(controller, 'identifier', {
      value: 'admin--user-search',
      writable: false,
      configurable: true
    })
    
    // Mock outlet properties (initially no outlets)
    Object.defineProperty(controller, 'hasGuardianPickerOutlet', {
      get: () => false,
      configurable: true
    })
    
    Object.defineProperty(controller, 'hasFlashOutlet', {
      get: () => false,
      configurable: true
    })
    
    // Mock the dispatch method
    controller.dispatch = jest.fn()
    
    // Mock utility methods from BaseFormController
    controller.safeTarget = jest.fn((targetName) => {
      const targetProperty = `${targetName}Target`
      return controller[targetProperty]
    })
    
    controller.withTarget = jest.fn((targetName, callback) => {
      const target = controller.safeTarget(targetName)
      if (target) {
        callback(target)
      }
    })
    
    controller.addDebouncedListener = jest.fn()
    controller.showErrorNotification = jest.fn()
    controller.showSuccessNotification = jest.fn()
    
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
  function createMockGuardianPickerOutlet() {
    const mockOutlet = {
      selectGuardian: jest.fn(),
      clearSelection: jest.fn()
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
  
  describe("guardian creation flow", () => {
    let mockedOutlet
    
    beforeEach(() => {
      mockedOutlet = createMockGuardianPickerOutlet()
      
      // Fill form with test data
      fixture.querySelector('[name="guardian_attributes[first_name]"]').value = "John"
      fixture.querySelector('[name="guardian_attributes[last_name]"]').value = "Doe"
      fixture.querySelector('[name="guardian_attributes[email]"]').value = "john@example.com"
      fixture.querySelector('[name="guardian_attributes[phone]"]').value = "555-1234"
      fixture.querySelector('[name="guardian_attributes[physical_address_1]"]').value = "123 Main St"
      fixture.querySelector('[name="guardian_attributes[city]"]').value = "Baltimore"
      fixture.querySelector('[name="guardian_attributes[zip_code]"]').value = "21201"
      fixture.querySelector('[name="guardian_attributes[date_of_birth]"]').value = "1980-01-01"
    })
    
    it("collects form data correctly", async () => {
      // Mock successful API response
      railsRequest.perform.mockResolvedValue({
        success: true,
        data: {
          success: true,
          user: {
            id: 123,
            first_name: "John",
            last_name: "Doe",
            email: "john@example.com",
            phone: "555-1234",
            physical_address_1: "123 Main St",
            city: "Baltimore",
            state: "MD",
            zip_code: "21201"
          }
        }
      })
      
      // Mock validation to pass
      controller.validateBeforeSubmit = jest.fn().mockResolvedValue({ valid: true })
      controller.handleSuccess = jest.fn()
      
      const createButton = fixture.querySelector('#createButton')
      const event = { target: createButton, preventDefault: jest.fn() }
      
      await controller.createGuardian(event)
      
      expect(railsRequest.perform).toHaveBeenCalledWith({
        method: 'post',
        url: '/admin/users',
        body: expect.objectContaining({
          first_name: "John",
          last_name: "Doe",
          email: "john@example.com"
        }),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        },
        key: 'create-guardian'
      })
    })
    
    it("handles successful guardian creation", async () => {
      const mockUserData = {
        id: 123,
        first_name: "John",
        last_name: "Doe",
        email: "john@example.com"
      }
      
      railsRequest.perform.mockResolvedValue({
        success: true,
        data: { user: mockUserData }
      })
      
      controller.validateBeforeSubmit = jest.fn().mockResolvedValue({ valid: true })
      controller.handleSuccess = jest.fn()
      
      const createButton = fixture.querySelector('#createButton')
      const event = { target: createButton, preventDefault: jest.fn() }
      
      await controller.createGuardian(event)
      
      expect(controller.handleSuccess).toHaveBeenCalledWith({ user: mockUserData })
    })
    
        it("shows loading state during creation", async () => {
      // Make sure form data is filled in so validation passes
      fixture.querySelector('[name="guardian_attributes[first_name]"]').value = "John"
      fixture.querySelector('[name="guardian_attributes[last_name]"]').value = "Doe"
      fixture.querySelector('[name="guardian_attributes[email]"]').value = "john@example.com"

      // Mock validation to always pass
      controller.validateBeforeSubmit = jest.fn().mockResolvedValue({ valid: true })

      // Mock a delayed API response
      let resolveRequest
      const requestPromise = new Promise(resolve => {
        resolveRequest = resolve
      })
      railsRequest.perform.mockReturnValue(requestPromise)

      controller.handleSuccess = jest.fn()

      const createButton = fixture.querySelector('#createButton')

      // Set up button properties for testing
      createButton.disabled = false
      createButton.textContent = 'Save Guardian'

      const event = { target: createButton, preventDefault: jest.fn() }

      // Start the creation process (don't await yet)
      const createPromise = controller.createGuardian(event)

      // Wait for validation to complete and button state to be set
      await new Promise(resolve => setTimeout(resolve, 0))
      
      expect(createButton.disabled).toBe(true)
      expect(createButton.textContent).toBe('Creating...')

      // Now resolve the request and wait for completion
      resolveRequest({ success: true, data: { user: {} } })
      await createPromise

      // Check restored state
      expect(createButton.disabled).toBe(false)
      expect(createButton.textContent).toBe('Save Guardian')
    })
    
    it("handles validation errors", async () => {
      const validationErrors = {
        first_name: "First name is required",
        email: "Email is required"
      }
      
      controller.validateBeforeSubmit = jest.fn().mockResolvedValue({
        valid: false,
        errors: validationErrors
      })
      controller.handleValidationErrors = jest.fn()
      
      const createButton = fixture.querySelector('#createButton')
      const event = { target: createButton, preventDefault: jest.fn() }
      
      await controller.createGuardian(event)
      
      expect(controller.handleValidationErrors).toHaveBeenCalledWith(validationErrors)
      expect(railsRequest.perform).not.toHaveBeenCalled()
    })
    
    it("handles API errors gracefully", async () => {
      railsRequest.perform.mockRejectedValue(new Error('Network error'))
      
      controller.validateBeforeSubmit = jest.fn().mockResolvedValue({ valid: true })
      
      const createButton = fixture.querySelector('#createButton')
      const event = { target: createButton, preventDefault: jest.fn() }
      
      await controller.createGuardian(event)
      
      // Button should be restored after error
      expect(createButton.disabled).toBe(false)
    })
    
    it("builds correct user display HTML", () => {
      const userData = {
        userEmail: "john@example.com",
        userPhone: "555-1234",
        userAddress1: "123 Main St",
        userCity: "Baltimore",
        userState: "MD",
        userZip: "21201",
        userDependentsCount: "2"
      }
      
      const html = controller.buildUserDisplayHTML("John Doe", userData)
      
      expect(html).toContain("John Doe")
      expect(html).toContain("john@example.com")
      expect(html).toContain("555-1234")
      expect(html).toContain("123 Main St")
      expect(html).toContain("Baltimore, MD, 21201")
    })
    
    it("escapes HTML in user display for security", () => {
      const userData = {
        userEmail: "john@example.com",
        userPhone: "555-1234"
      }
      
      // Test that escapeHtml method works correctly
      const maliciousName = "<script>alert('xss')</script> Doe"
      const escapedName = controller.escapeHtml(maliciousName)
      expect(escapedName).not.toContain("<script>")
      expect(escapedName).toContain("&lt;script&gt;")
      
      // Test that buildUserDisplayHTML uses the escaped name correctly
      const html = controller.buildUserDisplayHTML(escapedName, userData)
      expect(html).not.toContain("<script>")
      expect(html).toContain("&lt;script&gt;")
    })
  })
  
  describe("search functionality", () => {
    it("performs search with proper debouncing", async () => {
      // Mock the turbo frame target
      const mockTurboFrame = {
        src: null,
        setAttribute: jest.fn(),
        removeAttribute: jest.fn()
      }
      
      // Mock the safeTarget method to return our mock turbo frame
      controller.safeTarget = jest.fn().mockReturnValue(mockTurboFrame)
      
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = "John"
      
      const event = { target: searchInput }
      await controller.performSearch(event)
      
      // Verify that the turbo frame's src was set to trigger navigation
      expect(mockTurboFrame.src).toBe('/admin/users/search?q=John&role=guardian')
    })
    
    it("clears results when search is empty", async () => {
      controller.clearResults = jest.fn()
      
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = ""
      
      const event = { target: searchInput }
      await controller.performSearch(event)
      
      expect(controller.clearResults).toHaveBeenCalled()
      expect(railsRequest.perform).not.toHaveBeenCalled()
    })
  })
  
  describe("clearSearchAndShowForm", () => {
    it("clears search input and results but preserves guardian selection", () => {
      const mockedOutlet = createMockGuardianPickerOutlet()
      
      const searchInput = fixture.querySelector('#searchInput')
      searchInput.value = "test search"
      
      // Mock the withTarget method to actually call the callback
      controller.withTarget.mockImplementation((targetName, callback) => {
        if (targetName === 'searchInput') {
          callback(searchInput)
        }
      })
      
      controller.clearResults = jest.fn()
      
      controller.clearSearchAndShowForm()
      
      expect(searchInput.value).toBe("")
      expect(controller.clearResults).toHaveBeenCalled()
      // Guardian picker outlet should NOT be cleared
      expect(mockedOutlet.clearSelection).not.toHaveBeenCalled()
    })
  })
}) 